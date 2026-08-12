import SwiftUI

/// The Effects tab: a mirror of the 4×4 pad surface on the left, and the
/// parameters of whatever is currently in the chain on the right.
///
/// The grid is a *mirror*, not a control surface of its own — the pads are CC
/// toggles that latch in hardware, so the device owns the state and the app
/// follows. Clicking here works too (useful without the controller), but the
/// hardware always wins the next time a pad is pressed.
struct EffectsView: View {
    @EnvironmentObject var model: GranolaModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            padSurface
            Divider()
            chainDetail
        }
        .padding(12)
        .background(Theme.background)
    }

    // MARK: - Pad grid

    private var padSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            PadStatusView(pads: model.pads)

            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { column in
                            padButton(PadController.pad(forRow: row, column: column))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                legend(Theme.projectMode, "top two rows — tracks through FX")
                legend(Theme.reverbMode, "third row — grain envelope")
                legend(Theme.delayMode, "bottom row — chain slots")
                Text("tap a slot to assemble a random chain")
                    .font(Theme.mono).foregroundStyle(Theme.textDim)
                Text("⌥-click a lit slot to re-roll it")
                    .font(Theme.mono).foregroundStyle(Theme.textDim)
            }
            .padding(.top, 2)

            Divider().padding(.vertical, 2)
            chainSettings

            Spacer(minLength: 0)
        }
        .frame(width: 264)
    }

    /// How new chains are assembled. App-only by design: the controllers are
    /// performance instruments, not configuration surfaces.
    private var chainSettings: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CHAIN DEFAULTS").font(Theme.label).foregroundStyle(Theme.textDim)

            setting("Wet", value: $model.fxWetMix, range: 0...1,
                    format: String(format: "%.0f%%", model.fxWetMix * 100),
                    help: "Blend given to each new link. 40% transforms clearly without burying the source.")

            setting("Fade", value: $model.fxFadeTime, range: 0.05...15,
                    format: String(format: "%.1fs", model.fxFadeTime),
                    help: "How long a chain swells in when a slot is engaged, and fades out when released.")

            Toggle(isOn: $model.fxAutoGain) {
                Text("Auto gain match")
                    .font(Theme.mono)
                    .foregroundStyle(model.fxAutoGain ? Theme.text : Theme.textDim)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Scales each link's wet signal to match its dry level, so effects transform the sound without moving the loudness.")

            Text("applies to newly assembled chains")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.textDim.opacity(0.8))
        }
    }

    private func setting(_ label: String, value: Binding<Double>,
                         range: ClosedRange<Double>, format: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.mono).foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .leading)
            Slider(value: value, in: range)
            Text(format).font(Theme.mono).foregroundStyle(Theme.text)
                .frame(width: 40, alignment: .trailing)
        }
        .help(help)
    }

    private func legend(_ colour: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 8, height: 8)
            Text(text).font(Theme.mono).foregroundStyle(Theme.textDim)
        }
    }

    private func padButton(_ pad: Int) -> some View {
        let tint: Color = {
            if PadController.fxSlot(forPad: pad) != nil { return Theme.delayMode }
            if PadController.grainShape(forPad: pad) != nil { return Theme.reverbMode }
            return Theme.projectMode
        }()
        let active: Bool = {
            if let slot = PadController.fxSlot(forPad: pad) { return model.fxSlots[slot].isActive }
            if let shape = PadController.grainShape(forPad: pad) { return model.globalGrainShape == shape }
            if let track = PadController.trackIndex(forPad: pad) { return model.fxTracks.contains(track) }
            return false
        }()
        let caption: String = {
            if let slot = PadController.fxSlot(forPad: pad) {
                let count = model.fxSlots[slot].chain.count
                return count > 0 ? "S\(slot + 1)·\(count)" : "S\(slot + 1)"
            }
            if let shape = PadController.grainShape(forPad: pad) {
                return String(shape.label.prefix(4))
            }
            if let track = PadController.trackIndex(forPad: pad) { return "T\(track + 1)" }
            return ""
        }()

        return Button {
            toggle(pad, reroll: NSEvent.modifierFlags.contains(.option))
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? tint.opacity(0.28) : Theme.panelRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(active ? tint : Theme.stroke, lineWidth: active ? 1.6 : 1)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(caption)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(active ? tint : Theme.textDim)
                    Text("cc \(pad + 1)")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Theme.textDim.opacity(0.7))
                }
                .padding(5)
            }
            .frame(width: 56, height: 44)
        }
        .buttonStyle(.plain)
        .help(padHelp(pad))
    }

    private func padHelp(_ pad: Int) -> String {
        if let slot = PadController.fxSlot(forPad: pad) {
            let chain = model.fxSlots[slot]
            return chain.isActive ? "Slot \(slot + 1): \(chain.label)" : "Slot \(slot + 1) — empty"
        }
        if let shape = PadController.grainShape(forPad: pad) {
            return "Grain envelope: \(shape.label) — applies to all tracks"
        }
        if let track = PadController.trackIndex(forPad: pad) {
            return "Track \(track + 1) — \(model.fxTracks.contains(track) ? "through FX" : "direct to mix")"
        }
        return ""
    }

    private func toggle(_ pad: Int, reroll: Bool) {
        if let slot = PadController.fxSlot(forPad: pad) {
            if reroll && model.fxSlots[slot].isActive {
                model.rerollFXSlot(slot)
            } else {
                model.setFXSlot(slot, active: !model.fxSlots[slot].isActive)
            }
        } else if let shape = PadController.grainShape(forPad: pad) {
            model.setGrainShapeForAll(shape)
        } else if let track = PadController.trackIndex(forPad: pad) {
            model.setTrackThroughFX(track, enabled: !model.fxTracks.contains(track))
        }
    }

    // MARK: - Chain detail

    private var chainDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CHAIN").font(Theme.title).foregroundStyle(Theme.delayMode)
                Spacer()
                Text("\(model.catalog.count) Airwindows effects")
                    .font(Theme.mono).foregroundStyle(Theme.textDim)
            }

            Text(model.fxChainSummary)
                .font(Theme.mono)
                .foregroundStyle(model.activeChain.isEmpty ? Theme.textDim : Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if model.fxTracks.isEmpty && !model.activeChain.isEmpty {
                Text("no tracks routed — select tracks on the top two rows")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.selection)
            }

            Divider()

            if model.activeChain.isEmpty {
                Spacer()
                Text("no effects running")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.activeChain.enumerated()), id: \.element.link.id) { position, entry in
                            LinkEditor(position: position + 1, slot: entry.slot, link: entry.link)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Parameters for one link in the chain, live-editable.
private struct LinkEditor: View {
    @EnvironmentObject var model: GranolaModel
    let position: Int
    let slot: Int
    let link: FXInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(position).")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                Text(link.effect.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if link.isModulated {
                    Text("LFO → \(link.effect.label(link.lfoTarget))")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.panMode)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().stroke(Theme.panMode.opacity(0.6), lineWidth: 1))
                }
                Spacer()
                Text("slot \(slot + 1)")
                    .font(Theme.mono).foregroundStyle(Theme.textDim)
            }

            ForEach(0..<link.effect.paramCount, id: \.self) { index in
                HStack(spacing: 6) {
                    Text(link.effect.label(index))
                        .font(Theme.mono).foregroundStyle(Theme.textDim)
                        .frame(width: 72, alignment: .leading)
                        .lineLimit(1)
                    Slider(value: Binding(
                        get: { index < link.params.count ? link.params[index] : 0 },
                        set: { model.setEffectParam(slot: slot, link: link.id, index: index, value: $0) }
                    ), in: 0...1)
                    Text(String(format: "%.2f", index < link.params.count ? link.params[index] : 0))
                        .font(Theme.mono).foregroundStyle(Theme.text)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
                Text("MIX").font(Theme.mono).foregroundStyle(Theme.delayMode)
                    .frame(width: 72, alignment: .leading)
                Slider(value: Binding(
                    get: { link.mix },
                    set: { model.setEffectMix(slot: slot, link: link.id, value: $0) }
                ), in: 0...1)
                Text(String(format: "%.2f", link.mix))
                    .font(Theme.mono).foregroundStyle(Theme.text)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        )
    }
}


/// Observes the pad controller directly so its connection state updates
/// without republishing the whole app model.
struct PadStatusView: View {
    @ObservedObject var pads: PadController

    var body: some View {
        HStack(spacing: 6) {
            Text("SMC-PAD").font(Theme.title).foregroundStyle(Theme.text)
            Circle()
                .fill(pads.isConnected ? Theme.meterLow : Theme.textDim)
                .frame(width: 6, height: 6)
            Text(pads.statusText).font(Theme.mono).foregroundStyle(Theme.textDim)
        }
    }
}
