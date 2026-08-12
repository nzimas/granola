import Foundation

/// One Airwindows effect as described by the build-time manifest.
struct AirwindowsEffect: Codable, Identifiable, Hashable {
    let name: String
    let paramCount: Int
    let paramNames: [String]
    let defaults: [Double]

    var id: String { name }
    var synthDefName: String { "awfx_\(name)" }

    /// Airwindows exposes every parameter as 0…1, and the last one is very
    /// often Dry/Wet — worth knowing when randomising, so a chain link doesn't
    /// assemble itself with the wet signal turned down to nothing.
    var dryWetIndex: Int? {
        paramNames.firstIndex { $0.lowercased().contains("dry") || $0.lowercased() == "wet" }
    }

    func label(_ index: Int) -> String {
        guard index < paramNames.count, !paramNames[index].isEmpty else {
            return String(UnicodeScalar(65 + index)!)
        }
        return paramNames[index]
    }
}

/// The performance FX repertoire, read from the manifest that
/// Scripts/build-airwindows.sh produces alongside the compiled UGens.
final class AirwindowsCatalog {

    private(set) var effects: [AirwindowsEffect] = []

    init() {
        effects = Self.loadManifest()
    }

    var isEmpty: Bool { effects.isEmpty }
    var count: Int { effects.count }

    func effect(named name: String) -> AirwindowsEffect? {
        effects.first { $0.name == name }
    }

    private static func loadManifest() -> [AirwindowsEffect] {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL {
            candidates.append(bundled.appendingPathComponent("airwindows-manifest.json"))
        }
        // Development fallback, so `swift run` works before the bundle exists.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("vendor/airwindows/airwindows-manifest.json"))
            directory = directory.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/airwindows/airwindows-manifest.json"))

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([AirwindowsEffect].self, from: data)
            else { continue }
            return decoded
        }
        return []
    }

    // MARK: - Random assembly

    /// Builds a random chain link. Parameters are drawn across most of their
    /// range but kept off the extremes, where a lot of these algorithms either
    /// do nothing or turn to mush; dry/wet is biased upward so a randomly
    /// assembled link is always clearly audible — the whole point of a
    /// performance effect.
    func randomInstance(mixCentre: Double,
                        using generator: inout SystemRandomNumberGenerator) -> FXInstance? {
        guard let effect = effects.randomElement(using: &generator) else { return nil }

        var params = (0..<effect.paramCount).map { _ in Double.random(in: 0.15...0.9, using: &generator) }
        // Where a plugin has its own Dry/Wet, run it fully wet and let the
        // link's own `mix` be the single blend control. Two dry/wet stages in
        // series would make the blend unpredictable and hard to reason about.
        if let wet = effect.dryWetIndex, wet < params.count {
            params[wet] = 1.0
        }

        // Roughly one link in three gets movement.
        let modulated = Int.random(in: 0..<3, using: &generator) == 0 && effect.paramCount > 0
        return FXInstance(
            effect: effect,
            params: params,
            // Blend sits around the configured centre — enough to transform,
            // not enough to bury the source.
            mix: (mixCentre + Double.random(in: -0.08...0.08, using: &generator)).clamped(0.05, 1.0),
            lfoTarget: modulated ? Int.random(in: 0..<effect.paramCount, using: &generator) : -1,
            lfoRate: Double.random(in: 0.05...6.0, using: &generator),
            lfoDepth: modulated ? Double.random(in: 0.1...0.45, using: &generator) : 0,
            lfoShape: Int.random(in: 0...2, using: &generator)
        )
    }
}
