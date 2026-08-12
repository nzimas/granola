import SwiftUI

/// Visual language for the app: a dark control surface that reads like the
/// hardware sitting next to it.
enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let panelRaised = Color(red: 0.16, green: 0.16, blue: 0.19)
    static let stroke = Color.white.opacity(0.09)
    static let text = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let textDim = Color(red: 0.55, green: 0.56, blue: 0.60)

    /// One accent per macro slot, so a lit button, its encoder arc and its
    /// readout are all identifiable at a glance.
    ///
    /// These deliberately match the SMC-Mixer's physical LED colours, top to
    /// bottom on each strip: yellow, blue, red, white. The app is a picture of
    /// the hardware in front of you, so the colours have to agree.
    static func accent(_ slot: MacroSlot) -> Color {
        switch slot {
        case .grainSize: return Color(red: 1.00, green: 0.83, blue: 0.25)  // yellow
        case .density:   return Color(red: 0.36, green: 0.62, blue: 1.00)  // blue
        case .jitter:    return Color(red: 0.97, green: 0.33, blue: 0.30)  // red
        case .pitch:     return Color(red: 0.93, green: 0.94, blue: 0.97)  // white
        }
    }

    /// Encoder selector modes get their own colours, distinct from the four
    /// macro accents, so it is obvious at a glance that the encoders have been
    /// taken over.
    static let volumeMode = Color(red: 0.55, green: 0.75, blue: 1.00)
    static let panMode = Color(red: 0.80, green: 0.60, blue: 1.00)
    static let projectMode = Color(red: 0.98, green: 0.85, blue: 0.45)
    static let delayMode = Color(red: 0.40, green: 0.88, blue: 0.82)
    static let reverbMode = Color(red: 1.00, green: 0.58, blue: 0.45)

    static func encoderMode(_ mode: GranolaModel.EncoderMode) -> Color {
        switch mode {
        case .macro: return textDim
        case .volume: return volumeMode
        case .pan: return panMode
        case .delaySend: return delayMode
        case .reverbSend: return reverbMode
        }
    }

    static let selection = Color(red: 0.98, green: 0.78, blue: 0.25)
    /// The slot the current state came from. Deliberately red rather than the
    /// project panel's yellow, so "occupied" and "this is the one you loaded"
    /// never read as the same thing.
    static let projectCurrent = Color(red: 1.00, green: 0.32, blue: 0.36)
    static let meterLow = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let meterHigh = Color(red: 0.95, green: 0.40, blue: 0.35)
    static let waveform = Color(red: 0.45, green: 0.55, blue: 0.68)

    static let mono = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 10, weight: .semibold)
    static let title = Font.system(size: 13, weight: .semibold)
}

extension View {
    func panelBackground(_ corner: CGFloat = 8) -> some View {
        background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1)
                )
        )
    }
}
