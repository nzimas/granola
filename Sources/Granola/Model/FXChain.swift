import Foundation
import Combine

/// One link in a performance chain: an Airwindows effect with the parameters it
/// was randomly assembled with.
struct FXInstance: Identifiable {
    let id = UUID()
    let effect: AirwindowsEffect
    var params: [Double]
    var mix: Double
    /// Index of the parameter an LFO is moving, or -1 for none.
    var lfoTarget: Int
    var lfoRate: Double
    var lfoDepth: Double
    var lfoShape: Int

    /// Server node, assigned when the link is instantiated.
    var node: Int32 = 0

    var isModulated: Bool { lfoTarget >= 0 && lfoDepth > 0 }

    var summary: String {
        var text = effect.name
        if isModulated { text += " ~" }
        return text
    }
}

/// One of the eight pads on the bottom two rows: a slot holding a randomly
/// assembled chain of up to four effects.
final class FXSlot: ObservableObject, Identifiable {
    let index: Int
    var id: Int { index }

    @Published var isActive = false
    @Published var chain: [FXInstance] = []

    /// Order of activation, not slot number — the chain is built in the order
    /// pads were pressed, and closes up when one is removed.
    var activationOrder: Int = 0

    init(index: Int) { self.index = index }

    var label: String {
        chain.isEmpty ? "—" : chain.map(\.effect.name).joined(separator: " → ")
    }
}
