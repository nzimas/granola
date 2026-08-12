import SwiftUI

// MARK: - Encoder

/// Endless rotary control. Drag vertically to turn; matches the hardware
/// encoder above each strip, which is relative rather than absolute.
struct EncoderView: View {
    var value: Double            // 0…1, for the indicator arc only
    var tint: Color
    /// Draws the arc outward from centre instead of from the left, which is
    /// how a pan control should read.
    var bipolar: Bool = false
    var onTicks: (Int) -> Void

    /// Ticks already emitted for the current drag. Encoders are relative, so
    /// each frame reports only the change since the last one.
    @State private var emittedTicks = 0

    private var arcStart: Double { bipolar ? Swift.min(value.clamped(0, 1), 0.5) : 0 }
    private var arcEnd: Double { bipolar ? Swift.max(value.clamped(0, 1), 0.5) : value.clamped(0, 1) }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.panelRaised, Theme.panel],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))

                Circle()
                    .trim(from: 0.0, to: 0.75)
                    .stroke(Theme.stroke, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(3)

                Circle()
                    .trim(from: 0.75 * arcStart, to: 0.75 * arcEnd)
                    .stroke(tint,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(3)

                // Pointer
                Capsule()
                    .fill(tint)
                    .frame(width: 2, height: size * 0.22)
                    .offset(y: -size * 0.17)
                    .rotationEffect(.degrees(-135 + 270 * value.clamped(0, 1)))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // 3 px per tick, so a slow drag still resolves single steps.
                        let total = Int((-drag.translation.height / 3.0).rounded(.towardZero))
                        let delta = total - emittedTicks
                        if delta != 0 {
                            emittedTicks = total
                            onTicks(delta)
                        }
                    }
                    .onEnded { _ in emittedTicks = 0 }
            )
        }
    }
}

// MARK: - Fader

/// Vertical fader. On the hardware this scrubs the sample; here it does the
/// same thing, and the two stay in sync through the model.
struct FaderView: View {
    @Binding var value: Double
    var tint: Color
    /// Dimmed on an empty strip: there is no sample to scrub through.
    var enabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width
            let capHeight: CGFloat = 22
            let travel = max(height - capHeight, 1)
            let y = travel * (1 - CGFloat(value.clamped(0, 1)))

            ZStack(alignment: .top) {
                // Slot
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 5)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Theme.stroke, lineWidth: 1)
                            .frame(width: 5)
                            .frame(maxWidth: .infinity)
                    )

                // Travelled portion
                RoundedRectangle(cornerRadius: 3)
                    .fill(enabled ? tint.opacity(0.5) : Theme.textDim.opacity(0.3))
                    .frame(width: 5, height: max(0, height - y - capHeight / 2))
                    .frame(maxWidth: .infinity)
                    .offset(y: y + capHeight / 2)

                // Cap
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Theme.panelRaised, Color.black.opacity(0.8)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(enabled ? tint.opacity(0.9) : Theme.stroke, lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(tint)
                            .frame(height: 2)
                    )
                    .frame(width: width * 0.8, height: capHeight)
                    .frame(maxWidth: .infinity)
                    .offset(y: y)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let position = (drag.location.y - capHeight / 2) / travel
                        value = Double(1 - position).clamped(0, 1)
                    }
            )
        }
    }
}

// MARK: - Buttons

/// A hardware-style momentary/latching button with an LED.
struct SurfaceButton: View {
    var title: String
    var lit: Bool
    var tint: Color
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(lit ? tint.opacity(0.22) : Theme.panelRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(lit ? tint : Theme.stroke, lineWidth: lit ? 1.4 : 1)
                    )
                HStack(spacing: 4) {
                    Circle()
                        .fill(lit ? tint : Color.white.opacity(0.12))
                        .frame(width: 5, height: 5)
                        .shadow(color: lit ? tint.opacity(0.9) : .clear, radius: 3)
                    if !compact {
                        Text(title)
                            .font(Theme.label)
                            .foregroundStyle(lit ? tint : Theme.textDim)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Meter

struct MeterBar: View {
    var level: Double
    var horizontal = false

    private var normalized: Double {
        // Amplitude to a rough dB-ish scale so quiet material still moves.
        guard level > 0.0001 else { return 0 }
        let db = 20 * log10(level)
        return ((db + 60) / 60).clamped(0, 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let fill = normalized
            ZStack(alignment: horizontal ? .leading : .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(colors: [Theme.meterLow, Theme.meterLow, Theme.meterHigh],
                                       startPoint: horizontal ? .leading : .bottom,
                                       endPoint: horizontal ? .trailing : .top)
                    )
                    .frame(
                        width: horizontal ? geometry.size.width * fill : nil,
                        height: horizontal ? nil : geometry.size.height * fill
                    )
            }
        }
    }
}

/// The row of null-indicator LEDs above the faders on the hardware. Here it
/// shows the same thing: whether the app's scrub head agrees with the fader.
struct NullIndicator: View {
    var lit: Bool
    var tint: Color

    var body: some View {
        Circle()
            .fill(lit ? tint : Color.white.opacity(0.10))
            .frame(width: 6, height: 6)
            .shadow(color: lit ? tint.opacity(0.8) : .clear, radius: 3)
    }
}

/// Observes only the meter object, so a 15Hz level update redraws this bar and
/// nothing else in the strip.
struct TrackMeterBar: View {
    @ObservedObject var meter: MeterLevel

    var body: some View {
        MeterBar(level: meter.level)
    }
}

/// Same isolation for the master meter in the header.
struct MasterMeterBars: View {
    @ObservedObject var meter: StereoMeter

    var body: some View {
        VStack(spacing: 2) {
            MeterBar(level: meter.left, horizontal: true).frame(height: 4)
            MeterBar(level: meter.right, horizontal: true).frame(height: 4)
        }
    }
}
