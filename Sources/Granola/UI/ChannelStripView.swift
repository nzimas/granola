import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One channel strip, laid out top-to-bottom in the same order as the
/// hardware: encoder, null indicator, four macro buttons, fader.
struct ChannelStripView: View {
    @ObservedObject var track: TrackModel
    @EnvironmentObject var model: GranolaModel

    @State private var isTargetedForDrop = false
    @State private var showingImporter = false

    /// The strip's colour follows its first lit macro button, so a glance at
    /// the encoder tells you what it is holding. A global encoder selector
    /// overrides it.
    private var tint: Color {
        if model.encoderMode == .macro {
            if let slot = MacroSlot.allCases.first(where: { track.activeMacros.contains($0) }) {
                return Theme.accent(slot)
            }
            return Theme.textDim
        }
        return Theme.encoderMode(model.encoderMode)
    }

    /// With one macro lit the encoder arc shows that parameter. With several it
    /// shows their average, which is what a macro move actually does.
    private var encoderValue: Double {
        if track.showingFilter { return track.normalized(.filter) }
        if let param = model.encoderMode.param { return track.normalized(param) }
        let params = track.macroParams
        guard !params.isEmpty else { return 0 }
        return params.map { track.normalized($0) }.reduce(0, +) / Double(params.count)
    }

    private var encoderReadout: String {
        if track.showingFilter { return Self.formatFilter(track.value(.filter)) }
        switch model.encoderMode {
        case .macro: return track.macroReadout
        case .pan: return Self.formatPan(track.value(.pan))
        case .volume: return String(format: "%.2f", track.value(.level))
        case .delaySend, .reverbSend:
            guard let param = model.encoderMode.param else { return "—" }
            return String(format: "%.0f%%", track.value(param) * 100)
        }
    }

    /// The one-knob filter prints its side and its distance from centre, so a
    /// glance says both which filter is in and how far it has gone.
    static func formatFilter(_ value: Double) -> String {
        if abs(value) < 0.005 { return "FLT C" }
        return String(format: "%@ %.0f", value < 0 ? "LP" : "HP", abs(value) * 100)
    }

    /// Pan reads the way a mixer prints it: L64 … C … R64.
    static func formatPan(_ value: Double) -> String {
        if abs(value) < 0.005 { return "C" }
        return String(format: "%@%.0f", value < 0 ? "L" : "R", abs(value) * 100)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            waveform
            encoder
            macroButtons
            faderSection
            footer
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(track.selected ? Theme.panelRaised : Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isTargetedForDrop ? Theme.selection
                                : (track.selected ? Theme.selection.opacity(0.6) : Theme.stroke),
                                lineWidth: isTargetedForDrop ? 2 : 1)
                )
        )
        .onTapGesture { model.selectTrack(track.index) }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        // .audio covers the common cases, but some WAV/AIFF files on disk carry
        // no useful UTI, so the concrete types are listed too.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio, .wav, .aiff, .mp3, .mpeg4Audio],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.loadSample(url, into: track.index) }
            case .failure(let error):
                model.notice = error.localizedDescription
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 4) {
            Text("\(track.index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(track.selected ? Theme.selection : Theme.textDim)
            Spacer(minLength: 0)
            if track.channels >= 2 {
                Text("ST")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .help("Stereo — granulated as a sample-aligned buffer pair")
            } else if track.hasSample {
                Text("MO")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            TrackMeterBar(meter: track.meter)
                .frame(width: 4, height: 12)
        }
    }

    private var waveform: some View {
        VStack(spacing: 3) {
            WaveformView(
                peaks: track.waveform,
                waveformVersion: track.waveformVersion,
                position: track.value(.position),
                scatterFraction: track.value(.jitter) / 100,
                grainSeconds: track.value(.grainSize),
                density: track.value(.density),
                duration: track.duration,
                grainShape: track.grainShape,
                reversed: track.value(.reverse) >= 0.5,
                isPlaying: track.playing,
                tint: tint,
                isLoading: track.isLoading,
                // Scrubbing only makes sense once there is something to scrub;
                // an empty slot is a click target for loading instead.
                onScrub: track.hasSample
                    ? { model.setParameter(track.index, .position, value: $0) }
                    : nil
            )
            .frame(height: 46)
            .overlay {
                if !track.hasSample && !track.isLoading {
                    Button { showingImporter = true } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // The name doubles as the load button, so replacing a sample is a
            // single click whether or not the slot is already filled.
            Button { showingImporter = true } label: {
                Text(track.sampleName)
                    .font(Theme.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(track.hasSample ? Theme.text : Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(track.hasSample
                  ? "\(track.sampleURL?.path ?? "") — click to replace"
                  : "Click to load a sample")
        }
        .contextMenu {
            Button("Load Sample…") { showingImporter = true }
            if track.hasSample {
                Button("Clear Track") { model.clearSample(track.index) }
                if let url = track.sampleURL {
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    private var encoder: some View {
        VStack(spacing: 4) {
            EncoderView(
                value: encoderValue,
                tint: tint,
                bipolar: track.showingFilter || model.encoderMode == .pan,
                onTicks: { model.nudgeEncoder(track.index, byTicks: $0) }
            )
            .frame(height: 46)

            Text(encoderReadout)
                .font(Theme.mono)
                .foregroundStyle(track.showingFilter ? Theme.selection : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var macroButtons: some View {
        VStack(spacing: 4) {
            ForEach(MacroSlot.allCases) { slot in
                SurfaceButton(
                    title: slot.param.spec.short,
                    lit: track.activeMacros.contains(slot),
                    tint: Theme.accent(slot)
                ) {
                    model.toggleMacro(track.index, slot)
                }
                .frame(height: 20)
            }
        }
    }

    private var faderSection: some View {
        HStack(spacing: 4) {
            FaderView(
                value: model.binding(track.index, .position),
                tint: tint,
                enabled: track.hasSample
            )
            .frame(width: 34)

            TrackMeterBar(meter: track.meter)
                .frame(width: 4)
        }
        // Flexible rather than fixed: the fader absorbs whatever vertical space
        // is left, so the window fits screens shorter than the ideal layout.
        .frame(minHeight: 84, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            // Mute and solo live in the app: on the hardware, all four strip
            // buttons are taken by the macro toggles.
            HStack(spacing: 4) {
                SurfaceButton(title: "M", lit: track.mute, tint: Theme.meterHigh, compact: true) {
                    model.toggleMute(track.index)
                }
                SurfaceButton(title: "S", lit: track.solo, tint: Theme.selection, compact: true) {
                    model.toggleSolo(track.index)
                }
            }
            .frame(height: 18)

            Text(String(format: "%.2f", track.value(.position)))
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.loadSample(url, into: track.index) }
        }
        return true
    }
}
