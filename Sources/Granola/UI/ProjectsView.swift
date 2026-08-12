import SwiftUI

/// The eight project slots, mirroring the eight hardware buttons to the right
/// of Play / Stop / Record.
///
/// The Load/Save selector exists because a click has to mean one thing
/// unambiguously — on the controller that distinction is tap versus hold, which
/// has no natural mouse equivalent.
struct ProjectsPanel: View {
    @EnvironmentObject var model: GranolaModel

    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("PROJECTS").font(Theme.label).foregroundStyle(Theme.projectMode)
                Spacer()
                if model.projectLayerActive {
                    Text("SURFACE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.projectMode)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().stroke(Theme.projectMode.opacity(0.6), lineWidth: 1))
                        .help("The controller's buttons 2-10 are showing project slots")
                }
            }

            // Five then four: nine slots, readable in a narrow panel.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { slotTile($0) }
                }
                HStack(spacing: 4) {
                    ForEach(5..<ProjectStore.slotCount, id: \.self) { slotTile($0) }
                }
            }

            Picker("", selection: $saving) {
                Text("Load").tag(false)
                Text("Save").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 130)

            Text(saving ? "click a slot to overwrite it" : "click a slot to recall it")
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)

            if let current = model.currentProjectSlot {
                Text("slot \(current + 1) loaded")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.projectCurrent)
            }

            Text("scrub heads reset to 0 on load")
                .font(Theme.mono)
                .foregroundStyle(Theme.textDim)

            Spacer(minLength: 0)
        }
        .frame(width: 196, alignment: .leading)
    }

    private func slotTile(_ slot: Int) -> some View {
        let occupied = model.occupiedSlots.indices.contains(slot) && model.occupiedSlots[slot]
        let isCurrent = model.currentProjectSlot == slot
        let isBlinking = model.savingSlot == slot
        // Blink wins over everything while it lasts, then the current slot's
        // red, then plain occupancy.
        let accent = isBlinking ? Color.white
            : (isCurrent ? Theme.projectCurrent
               : (occupied ? Theme.projectMode : Theme.stroke))
        return Button {
            if saving {
                model.saveProject(to: slot)
            } else {
                model.loadProject(from: slot)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isBlinking ? Color.white.opacity(0.85)
                          : (isCurrent ? Theme.projectCurrent.opacity(0.28)
                             : (occupied ? Theme.projectMode.opacity(0.22) : Theme.panelRaised)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(accent, lineWidth: isCurrent || isBlinking ? 1.8 : (occupied ? 1.3 : 1))
                    )
                    // The glow is what carries across the room; the border alone
                    // is easy to miss on a 21pt tile.
                    .shadow(color: isCurrent || isBlinking ? accent.opacity(0.9) : .clear,
                            radius: isBlinking ? 6 : 4)
                Text("\(slot + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isBlinking ? Theme.background
                                     : (isCurrent ? Theme.projectCurrent
                                        : (occupied ? Theme.projectMode : Theme.textDim)))
            }
            .frame(width: 21, height: 22)
        }
        .buttonStyle(.plain)
        .help(slotHelp(slot, occupied: occupied, isCurrent: isCurrent))
        .contextMenu {
            Button("Save to Slot \(slot + 1)") { model.saveProject(to: slot) }
            if occupied {
                Button("Load Slot \(slot + 1)") { model.loadProject(from: slot) }
                Divider()
                Button("Clear Slot \(slot + 1)", role: .destructive) { model.clearProject(slot: slot) }
            }
        }
    }

    private func slotHelp(_ slot: Int, occupied: Bool, isCurrent: Bool) -> String {
        guard occupied, let snapshot = model.projects.slots[slot] else {
            return "Slot \(slot + 1) — empty"
        }
        let here = isCurrent ? " — currently loaded" : ""
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Slot \(slot + 1)\(here) — \(snapshot.loadedTrackCount) track(s), "
            + "saved \(formatter.string(from: snapshot.savedAt))"
    }
}
