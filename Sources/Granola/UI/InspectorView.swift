import SwiftUI

/// Full parameter set for the selected track — everything the four macro
/// buttons can't reach from the hardware.
struct InspectorView: View {
    @EnvironmentObject var model: GranolaModel

    private var track: TrackModel { model.tracks[model.selectedTrack] }

    private let cloud: [ParamID] = [.grainSize, .density, .jitter, .drift, .posLag, .scan]
    private let pitch: [ParamID] = [.pitch, .pitchJitter, .pitchQuant, .reverse, .freeze]
    private let tone: [ParamID] = [.filter, .lpf, .hpf, .resonance]
    private let space: [ParamID] = [.pan, .spread, .level, .delaySend, .reverbSend]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                // Projects sit first: they are reached mid-performance, and the
                // inspector scrolls horizontally on a 1280-wide screen.
                ProjectsPanel()
                TrackPanel(track: track)
                group("CLOUD", cloud)
                group("PITCH", pitch)
                group("TONE", tone)
                group("MIX", space)
                delayPanel
                reverbPanel
            }
            .padding(10)
        }
        .panelBackground()
    }

    private func group(_ title: String, _ params: [ParamID]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.label).foregroundStyle(Theme.textDim)
            ForEach(params) { param in
                ParamRow(param: param, track: track)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 172, alignment: .leading)
    }

    private var delayPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("DELAY").font(Theme.label).foregroundStyle(Theme.delayMode)
                Spacer()
                Button(model.delayCrossFeed >= 0.99 ? "ping-pong" : "stereo") {
                    model.setPingPong(model.delayCrossFeed < 0.99)
                }
                .buttonStyle(.plain)
                .font(Theme.mono)
                .foregroundStyle(model.delayCrossFeed >= 0.99 ? Theme.delayMode : Theme.textDim)
                Button(model.delayFreeze ? "frozen" : "freeze") {
                    model.delayFreeze.toggle()
                }
                .buttonStyle(.plain)
                .font(Theme.mono)
                .foregroundStyle(model.delayFreeze ? Theme.selection : Theme.textDim)
            }
            // Up to 10 s per side, set independently — the whole point of a
            // malleable stereo delay.
            labelledSlider("Time L", $model.delayTimeL, 0.001...GranolaModel.maxDelayTime, "s", 3)
            labelledSlider("Time R", $model.delayTimeR, 0.001...GranolaModel.maxDelayTime, "s", 3)
            labelledSlider("Fdbk", $model.delayFeedback, 0...0.98)
            labelledSlider("Cross", $model.delayCrossFeed, 0...1)
            labelledSlider("Damp", $model.delayDamp, 200...18000, "Hz", 0)
            labelledSlider("Blur", $model.delayDiffusion, 0...1)
            labelledSlider("Mod", $model.delayModDepth, 0...1)
            labelledSlider("Width", $model.delayWidth, 0...2)
            labelledSlider("Level", $model.delayLevel, 0...1.5)
            Spacer(minLength: 0)
        }
        .frame(width: 196, alignment: .leading)
    }

    private var reverbPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("REVERB · JPverb").font(Theme.label).foregroundStyle(Theme.reverbMode)
            labelledSlider("Decay", $model.reverbDecay, 0.1...30, "s", 1)
            labelledSlider("Size", $model.reverbSize, 0.5...5)
            labelledSlider("Damp", $model.reverbDamp, 0...1)
            labelledSlider("Predly", $model.reverbPredelay, 0...0.5, "s", 3)
            labelledSlider("Mod", $model.reverbModDepth, 0...1)
            labelledSlider("HF Dcy", $model.reverbHighMult, 0...1)
            labelledSlider("Width", $model.reverbWidth, 0...2)
            labelledSlider("Level", $model.reverbLevel, 0...1.5)
            Spacer(minLength: 0)
        }
        .frame(width: 196, alignment: .leading)
    }

    private func labelledSlider(_ title: String, _ value: Binding<Double>,
                                _ range: ClosedRange<Double>,
                                _ unit: String = "", _ digits: Int = 2) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.mono).foregroundStyle(Theme.textDim)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.\(digits)f%@", value.wrappedValue, unit))
                .font(Theme.mono).foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The selected track's identity and its grain envelope.
///
/// This has to be its own view with `@ObservedObject`. Reaching the track
/// through a computed property on the inspector meant the inspector never
/// observed it, so the envelope Picker re-read a stale value after every
/// selection and snapped back to the first entry — even though the engine had
/// already changed shape.
struct TrackPanel: View {
    @ObservedObject var track: TrackModel
    @EnvironmentObject var model: GranolaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRACK \(track.index + 1)")
                .font(Theme.title)
                .foregroundStyle(Theme.selection)
            Text(track.sampleName)
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            if track.hasSample {
                Text(String(format: "%.2f s · %@", track.duration,
                            track.channels >= 2 ? "stereo" : "mono"))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textDim)
            }
            if track.extraChannelsIgnored > 0 {
                Text("+\(track.extraChannelsIgnored) ch ignored")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.selection)
            }
            if let error = track.loadError {
                Text(error).font(Theme.mono).foregroundStyle(Theme.meterHigh).lineLimit(3)
            }

            Text("GRAIN ENVELOPE").font(Theme.label).foregroundStyle(Theme.textDim)
                .padding(.top, 2)
            Picker("", selection: Binding(
                get: { track.grainShape },
                set: { model.setGrainShape(track.index, $0) }
            )) {
                ForEach(GranolaEngine.GrainShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
            .help("Amplitude contour applied to every grain")

            Spacer(minLength: 0)
        }
        .frame(width: 150, alignment: .leading)
    }
}

/// One parameter: name, control, formatted value. Toggle-curve parameters get
/// a switch instead of a slider.
struct ParamRow: View {
    let param: ParamID
    @ObservedObject var track: TrackModel
    @EnvironmentObject var model: GranolaModel

    var body: some View {
        let spec = param.spec
        HStack(spacing: 6) {
            Text(spec.short)
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
                .frame(width: 44, alignment: .leading)

            if spec.curve == .toggle {
                Toggle("", isOn: Binding(
                    get: { track.value(param) >= 0.5 },
                    set: { model.setParameter(track.index, param, value: $0 ? 1 : 0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            } else {
                // Sliders operate in normalised space so exponential parameters
                // feel even across their whole range.
                Slider(value: Binding(
                    get: { track.normalized(param) },
                    set: { model.setNormalized(track.index, param, $0) }
                ), in: 0...1)
            }

            Text(spec.format(track.value(param)))
                .font(Theme.mono)
                .foregroundStyle(Theme.text)
                .frame(width: 62, alignment: .trailing)
        }
        .help(spec.label)
    }
}
