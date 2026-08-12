import Foundation

/// A complete snapshot of the machine, minus the scrub heads.
///
/// Scrub position is deliberately **not** stored. On load every head returns to
/// zero, so the performer knows the faders belong at the bottom and the
/// hardware and the app start in agreement. Restoring positions would leave
/// eight physical faders sitting wherever they happened to be, silently
/// disagreeing with the app until each one was touched.
struct ProjectSnapshot: Codable {

    /// Bumped when the format changes in a way older files cannot satisfy.
    /// v2 moved Scatter from seconds to a percentage of the sample. Older
    /// files are converted on load, once the sample's duration is known.
    static let currentVersion = 2

    var version: Int = ProjectSnapshot.currentVersion
    var name: String
    var savedAt: Date

    var tracks: [TrackSnapshot]
    var master: MasterSnapshot

    struct TrackSnapshot: Codable {
        var samplePath: String?
        var sampleBookmark: Data?
        var sampleName: String
        /// Parameter values by `ParamID.rawValue`. Unknown keys are ignored on
        /// load, so a file from a build with extra parameters still opens.
        var values: [String: Double]
        var mute: Bool
        var solo: Bool
        var activeMacros: [Int]
        var grainShape: Int
    }

    struct MasterSnapshot: Codable {
        var level: Double

        var reverbDecay: Double
        var reverbSize: Double
        var reverbDamp: Double
        var reverbPredelay: Double
        var reverbModDepth: Double
        var reverbHighMult: Double
        var reverbWidth: Double
        var reverbLevel: Double

        var delayTimeL: Double
        var delayTimeR: Double
        var delayFeedback: Double
        var delayCrossFeed: Double
        var delayDamp: Double
        var delayDiffusion: Double
        var delayModDepth: Double
        var delayWidth: Double
        var delayFreeze: Bool
        var delayLevel: Double
    }

    /// Short summary for the UI: how many tracks actually carry a sample.
    var loadedTrackCount: Int {
        tracks.filter { $0.samplePath != nil }.count
    }
}

/// Eight save slots on disk, mirroring the eight hardware buttons.
final class ProjectStore {

    /// Nine slots: buttons 2 to 10.
    ///
    /// The eleventh button is the shift modifier and nothing else. It briefly
    /// doubled as slot 10, which made that slot impossible to save into —
    /// holding it was indistinguishable from holding shift.
    static let slotCount = 9

    private static let migrationMarker = "migrated-to-10-slots"
    private static let slotShift = 2
    private static let nineSlotMarker = "migrated-to-9-slots"

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Cached slot contents so the UI and the LED refresh do not hit the disk
    /// on every redraw.
    private(set) var slots: [ProjectSnapshot?]

    init() {
        // The self-test writes real projects, so it gets a scratch directory.
        // Pointing it at the live one would destroy the performer's slots.
        if CommandLine.arguments.contains("--self-test") {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("granola-selftest-projects", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appendingPathComponent("Granola/Projects", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        slots = Array(repeating: nil, count: Self.slotCount)
        migrateIfNeeded()
        migrateToNineSlots()
        reload()
    }

    /// One-time renumbering. Walks downward so a project is never written over
    /// one that has not moved yet.
    private func migrateIfNeeded() {
        let marker = directory.appendingPathComponent(Self.migrationMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        var moved = 0
        for slot in stride(from: 7, through: 0, by: -1) {
            let from = url(for: slot)
            let to = url(for: slot + Self.slotShift)
            guard FileManager.default.fileExists(atPath: from.path),
                  !FileManager.default.fileExists(atPath: to.path) else { continue }
            try? FileManager.default.moveItem(at: from, to: to)
            moved += 1
        }
        try? Data().write(to: marker)
        if moved > 0 {
            NSLog("Granola: moved %d project(s) up by %d slots", moved, Self.slotShift)
        }
    }

    /// Slot 10 no longer exists, so anything saved on the last two buttons
    /// moves one button left. Walks upward so a project is never written over
    /// one that has not moved yet.
    private func migrateToNineSlots() {
        let marker = directory.appendingPathComponent(Self.nineSlotMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        var moved = 0
        for slot in [8, 9] {                     // slots 9 and 10, zero-based
            let from = url(for: slot)
            let to = url(for: slot - 1)
            guard FileManager.default.fileExists(atPath: from.path),
                  !FileManager.default.fileExists(atPath: to.path) else { continue }
            try? FileManager.default.moveItem(at: from, to: to)
            moved += 1
        }
        try? Data().write(to: marker)
        if moved > 0 { NSLog("Granola: moved %d project(s) one slot left", moved) }
    }

    func url(for slot: Int) -> URL {
        directory.appendingPathComponent("slot-\(slot + 1).json")
    }

    var directoryURL: URL { directory }

    func reload() {
        for slot in 0..<Self.slotCount {
            slots[slot] = read(slot)
        }
    }

    private func read(_ slot: Int) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: url(for: slot)) else { return nil }
        return try? decoder.decode(ProjectSnapshot.self, from: data)
    }

    func isOccupied(_ slot: Int) -> Bool {
        slots.indices.contains(slot) && slots[slot] != nil
    }

    @discardableResult
    func save(_ snapshot: ProjectSnapshot, to slot: Int) throws -> URL {
        let destination = url(for: slot)
        let data = try encoder.encode(snapshot)
        // Atomic: a half-written project file would be worse than none.
        try data.write(to: destination, options: .atomic)
        slots[slot] = snapshot
        return destination
    }

    func load(_ slot: Int) -> ProjectSnapshot? {
        guard slots.indices.contains(slot) else { return nil }
        if slots[slot] == nil { slots[slot] = read(slot) }
        return slots[slot]
    }

    func clear(_ slot: Int) {
        try? FileManager.default.removeItem(at: url(for: slot))
        slots[slot] = nil
    }
}
