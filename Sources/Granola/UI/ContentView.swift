import SwiftUI

/// The two workspaces. Mixer is the default; Effects is the performance FX
/// surface driven by the SMC-PAD.
enum Workspace: String, CaseIterable, Identifiable {
    case mixer = "MIXER"
    case effects = "EFFECTS"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: GranolaModel
    @State private var workspace: Workspace = CommandLine.arguments.contains("--tab-effects") ? .effects : .mixer

    var body: some View {
        VStack(spacing: 10) {
            HeaderView(workspace: $workspace)
            if workspace == .effects {
                EffectsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .panelBackground()
            } else {
                mixerWorkspace
            }
        }
        .padding(12)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .frame(minWidth: 1120, minHeight: 560)
    }

    private var mixerWorkspace: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.tracks) { track in
                    ChannelStripView(track: track)
                        .frame(minWidth: 108, maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            GlobalBarView()

            // Fixed-height and scrollable: the inspector holds more than a
            // 1280x800 screen can show, and it must not push the strips off.
            InspectorView()
                .frame(height: 186)
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var model: GranolaModel
    @Binding var workspace: Workspace

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("GRANOLA")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.text)
            }

            Picker("", selection: $workspace) {
                ForEach(Workspace.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 170)

            Divider().frame(height: 20)

            StatusPill(
                label: model.statusText,
                tint: model.isRunning ? Theme.meterLow : Theme.meterHigh
            )

            if !model.isRunning {
                Button("Restart engine") { model.restartEngine() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            MixerStatusView(mixer: model.mixer)

            if model.shiftHeld {
                Text("SHIFT")
                    .font(Theme.label)
                    .foregroundStyle(Theme.selection)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().stroke(Theme.selection, lineWidth: 1))
            }

            Spacer()

            if model.encoderMode != .macro {
                let tint = Theme.encoderMode(model.encoderMode)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text("ENCODERS → \(model.encoderMode.label.uppercased())")
                        .font(Theme.label)
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
            }

            if let notice = model.notice {
                Text(notice)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.selection)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .onTapGesture { model.notice = nil }
            }

            // Master
            HStack(spacing: 6) {
                Text("MASTER").font(Theme.label).foregroundStyle(Theme.textDim)
                Slider(value: $model.masterLevel, in: 0...1.2)
                    .frame(width: 110)
                MasterMeterBars(meter: model.masterMeter)
                    .frame(width: 60)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .panelBackground()
    }
}

struct StatusPill: View {
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(Theme.mono).foregroundStyle(Theme.textDim).lineLimit(1)
        }
    }
}

struct MixerStatusView: View {
    @ObservedObject var mixer: SMCMixer

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(
                label: mixer.isConnected ? "SMC-Mixer · \(mixer.mode.rawValue)" : mixer.statusText,
                tint: mixer.isConnected ? (mixer.mode == .daw ? Theme.meterLow : Theme.selection)
                                        : Theme.textDim
            )
            if mixer.needsDAWModeSwitch {
                Text("hold Shift + Left/Right to switch to DAW mode")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.selection)
            }
        }
    }
}

// MARK: - Global bar

/// Mirrors the hardware's bottom row. The labels say what each button does in
/// Granola, since the device's printed legends are transport names.
struct GlobalBarView: View {
    @EnvironmentObject var model: GranolaModel

    var body: some View {
        HStack(spacing: 6) {
            // Mirrors the hardware exactly: button 1 is a single latching
            // play/stop toggle, and buttons 2-5 are the encoder selectors —
            // the five buttons that latch in the device's firmware.
            SurfaceButton(title: model.isPlaying ? "PLAYING" : "STOPPED",
                          lit: model.isPlaying,
                          tint: Theme.meterLow) { model.toggleTransport() }
            SurfaceButton(title: "VOL", lit: model.encoderMode == .volume,
                          tint: Theme.volumeMode) { model.setEncoderMode(.volume) }
            SurfaceButton(title: "PAN", lit: model.encoderMode == .pan,
                          tint: Theme.panMode) { model.setEncoderMode(.pan) }
            SurfaceButton(title: "DLY", lit: model.encoderMode == .delaySend,
                          tint: Theme.delayMode) { model.setEncoderMode(.delaySend) }
            SurfaceButton(title: "RVB", lit: model.encoderMode == .reverbSend,
                          tint: Theme.reverbMode) { model.setEncoderMode(.reverbSend) }

            Divider().frame(height: 18)

            Divider().frame(height: 18)

            // Positions 6-10 come straight from the hardware table, so the
            // window cannot drift from the surface.
            ForEach(GranolaModel.globalRow.filter { (6...10).contains($0.position) }, id: \.position) { entry in
                SurfaceButton(title: entry.name,
                              lit: entry.lit?(model) ?? false,
                              tint: Theme.text) { entry.action?(model) }
            }

            // Mirrors Shift + Play on the controller.
            SurfaceButton(title: "PROJ", lit: model.projectLayerActive,
                          tint: Theme.projectMode) { model.toggleProjectLayer() }

            Spacer()

            // Displaced from the hardware row by the encoder selectors; still
            // reachable here and from the Transport menu.
            SurfaceButton(title: "SHAPE −", lit: false, tint: Theme.text) {
                model.cycleGrainShapeForSelected(by: -1)
            }
            SurfaceButton(title: "SHAPE +", lit: false, tint: Theme.text) {
                model.cycleGrainShapeForSelected(by: 1)
            }
            SurfaceButton(title: "REWIND", lit: false, tint: Theme.text) { model.rewindAll() }
            SurfaceButton(title: "REC OUT", lit: model.isRecording,
                          tint: Theme.meterHigh) { model.toggleRecording() }
            SurfaceButton(title: "PANIC", lit: false, tint: Theme.meterHigh) { model.panic() }
        }
        .frame(height: 26)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .panelBackground()
    }
}
