import SwiftUI

/// The waveform overview itself.
///
/// Split out and made `Equatable` on a version counter so SwiftUI can skip it
/// entirely: this canvas is the most expensive thing in the window, and it only
/// changes when a new sample is loaded. Without this gate it redrew on every
/// meter tick and every fader move — hundreds of times a second.
private struct WaveformCanvas: View, Equatable {
    let peaks: [Float]
    let version: Int

    static func == (lhs: WaveformCanvas, rhs: WaveformCanvas) -> Bool {
        lhs.version == rhs.version
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard !peaks.isEmpty else { return }
            var path = Path()
            let count = peaks.count
            let step = size.width / CGFloat(count)
            let mid = size.height / 2

            for index in 0..<count {
                let x = CGFloat(index) * step
                let amplitude = CGFloat(peaks[index]) * mid * 0.94
                path.move(to: CGPoint(x: x, y: mid - amplitude))
                path.addLine(to: CGPoint(x: x, y: mid + amplitude))
            }
            context.stroke(path, with: .color(Theme.waveform), lineWidth: max(step, 0.7))
        }
        .padding(.horizontal, 2)
    }
}

/// The live grain cloud, drawn over the waveform.
///
/// The server does not report individual grains — at 200 grains a second it
/// shouldn't — so this reconstructs them from the same parameters the voice is
/// running on. Grain *n* is the one that fired at `n / density`, which makes the
/// whole cloud a pure function of the clock: no particle list, no per-frame
/// state, nothing to keep in sync. Each grain is drawn as a horizontal bar
/// starting where it scattered to and running as long as it reads, so density
/// shows up as how crowded the picture is and grain size as how long the bars
/// are — the two things the encoders are actually moving.
private struct GrainCloudView: View {
    let position: Double
    let scatterFraction: Double
    let grainSeconds: Double
    let density: Double
    let duration: Double
    let shape: GranolaEngine.GrainShape
    let reversed: Bool
    let tint: Color

    /// Above this the picture is a solid block anyway, and the cost stops being
    /// free. Beyond it grains are sampled evenly across ages rather than
    /// truncated, so a dense cloud still looks dense rather than young.
    private static let maxDrawn = 48

    /// Cheap deterministic hash — grain *n* must scatter to the same place on
    /// every frame or the cloud would boil.
    private static func hash(_ n: Int, _ salt: UInt64) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ salt
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x >> 11) * (1.0 / 9007199254740992.0)   // 0…1
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                guard duration > 0 else { return }
                let now = timeline.date.timeIntervalSinceReferenceDate
                let life = grainSeconds.clamped(0.002, 2.0)
                let rate = density.clamped(0.2, 200)

                let newest = Int((now * rate).rounded(.down))
                let oldest = Int(((now - life) * rate).rounded(.up))
                guard newest >= oldest else { return }
                let stride = max(1, (newest - oldest + 1) / Self.maxDrawn)

                let length = max(CGFloat(life / duration) * size.width, 1.5)
                let jitterSpan = scatterFraction

                var index = newest
                while index >= oldest {
                    let age = now - Double(index) / rate
                    let phase = (age / life).clamped(0, 1)
                    let amplitude = Double(shape.sample(at: phase))

                    let scatter = (Self.hash(index, 0x51ED270B) * 2 - 1) * jitterSpan
                    let start = (position + scatter).clamped(0, 1)
                    let x = CGFloat(start) * size.width
                    // Lanes keep overlapping grains legible; without them a
                    // dense cloud collapses into one flat bar.
                    let lane = Self.hash(index, 0xA24BAED4) * 0.72 + 0.14
                    let y = CGFloat(lane) * size.height

                    let rect = CGRect(x: reversed ? x - length : x,
                                      y: y - 1, width: length, height: 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(tint.opacity(amplitude * 0.7)))
                    index -= stride
                }
            }
        }
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

/// Waveform overview with the scrub head drawn on top, plus the region the
/// grain cloud is actually drawing from (position ± jitter).
struct WaveformView: View {
    var peaks: [Float]
    var waveformVersion: Int
    var position: Double
    var scatterFraction: Double
    var grainSeconds: Double
    var density: Double
    var duration: Double
    var grainShape: GranolaEngine.GrainShape
    var reversed: Bool
    var isPlaying: Bool
    var tint: Color
    var isLoading: Bool
    var onScrub: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.45))

                if peaks.isEmpty {
                    Text(isLoading ? "loading…" : "click to load")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    WaveformCanvas(peaks: peaks, version: waveformVersion)
                        .equatable()

                    // Grain scatter region
                    if duration > 0, scatterFraction > 0.0002 {
                        let spread = CGFloat(scatterFraction.clamped(0, 1)) * width
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tint.opacity(0.16))
                            .frame(width: max(spread * 2, 2))
                            .offset(x: CGFloat(position.clamped(0, 1)) * width - spread)
                    }

                    // Live grains. Only while the voice is running: a stopped
                    // track should not be animating anything.
                    if isPlaying, duration > 0 {
                        GrainCloudView(
                            position: position,
                            scatterFraction: scatterFraction,
                            grainSeconds: grainSeconds,
                            density: density,
                            duration: duration,
                            shape: grainShape,
                            reversed: reversed,
                            tint: tint
                        )
                    }

                    // Scrub head
                    Rectangle()
                        .fill(tint)
                        .frame(width: 1.5)
                        .shadow(color: tint.opacity(0.8), radius: 3)
                        .offset(x: CGFloat(position.clamped(0, 1)) * width - 0.75)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard let onScrub, width > 0 else { return }
                        onScrub(Double(drag.location.x / width).clamped(0, 1))
                    }
            )
        }
    }
}
