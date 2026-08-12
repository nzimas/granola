import Foundation
import Combine

/// One of the eight channel strips: a sample, a grain cloud, and the state of
/// the four macro buttons that decide what this strip's encoder is holding.
final class TrackModel: ObservableObject, Identifiable {

    let index: Int
    var id: Int { index }

    // MARK: - Sample

    @Published var sampleURL: URL?
    @Published var sampleName: String = "—"
    @Published var duration: Double = 0
    @Published var channels: Int = 2
    @Published var waveform: [Float] = [] { didSet { waveformVersion &+= 1 } }
    @Published var isLoading = false
    @Published var loadError: String?

    var hasSample: Bool { sampleURL != nil && duration > 0 }

    // MARK: - Parameters

    @Published private(set) var values: [ParamID: Double] = {
        var defaults: [ParamID: Double] = [:]
        for param in ParamID.allCases { defaults[param] = param.spec.defaultValue }
        return defaults
    }()

    func value(_ param: ParamID) -> Double { values[param] ?? param.spec.defaultValue }

    func normalized(_ param: ParamID) -> Double {
        param.spec.normalized(fromValue: value(param))
    }

    /// Returns true when the value actually moved, so callers can skip
    /// redundant OSC traffic — which matters on the BLE feedback path.
    @discardableResult
    func setValue(_ param: ParamID, _ newValue: Double) -> Bool {
        let spec = param.spec
        let clamped = newValue.clamped(spec.min, spec.max)
        guard abs((values[param] ?? .nan) - clamped) > 1e-9 || values[param] == nil else { return false }
        values[param] = clamped
        return true
    }

    @discardableResult
    func setNormalized(_ param: ParamID, _ t: Double) -> Bool {
        setValue(param, param.spec.value(fromNormalized: t))
    }

    @discardableResult
    func nudgeNormalized(_ param: ParamID, by delta: Double) -> Bool {
        setNormalized(param, normalized(param) + delta)
    }

    // MARK: - Strip state

    @Published var mute = false
    @Published var solo = false
    /// The strip's "Rec" button arms it as a randomisation / macro-write target.
    @Published var armed = false
    @Published var selected = false
    @Published var playing = false

    /// Which of the four macro buttons are lit. More than one lit turns the
    /// encoder into a macro that moves all of them together.
    @Published var activeMacros: Set<MacroSlot> = [.grainSize]

    /// Its own object so 15Hz metering does not republish the whole track.
    let meter = MeterLevel()

    /// Bumped only when the waveform itself changes, so the (expensive) canvas
    /// can skip redrawing on parameter and meter updates.
    private(set) var waveformVersion = 0

    /// Set when a pre-v2 project is restored: Scatter was stored in seconds
    /// back then, and converting it to a share of the sample needs a duration
    /// the loader has not reported yet. Consumed by `applyLoadedSample`.
    var pendingScatterSeconds: Double?

    /// True from the first shift-held encoder tick on this strip until shift is
    /// released, so the strip can show the filter instead of whatever the
    /// selectors are pointing at. Not persisted — it is a display state that
    /// lasts exactly as long as the gesture.
    @Published var showingFilter = false

    /// Window shape applied to every grain on this track.
    @Published var grainShape: GranolaEngine.GrainShape = .gaussian

    /// Set when a file has more channels than the engine granulates, so the UI
    /// can say so rather than silently dropping content.
    @Published var extraChannelsIgnored = 0

    // MARK: - Server-side identity

    var bufferNumber: Int32
    var voiceNode: Int32 = 0
    var stripNode: Int32 = 0

    init(index: Int) {
        self.index = index
        self.bufferNumber = Int32(index)
    }

    // MARK: - Macro handling

    func toggleMacro(_ slot: MacroSlot) {
        if activeMacros.contains(slot) {
            activeMacros.remove(slot)
        } else {
            activeMacros.insert(slot)
        }
    }

    /// What the encoder falls back to when none of the four macro buttons are
    /// lit. An unlit strip used to have a dead knob; Drift is the one cloud
    /// control with no button of its own, so it costs nothing to reach and
    /// always has somewhere useful to go.
    static let unassignedParam: ParamID = .drift

    /// The parameters an encoder turn should move, in a stable order.
    var macroParams: [ParamID] {
        let lit = MacroSlot.allCases.filter { activeMacros.contains($0) }.map(\.param)
        return lit.isEmpty ? [Self.unassignedParam] : lit
    }

    var macroLabel: String {
        let params = macroParams
        return params.count == 1 ? params[0].spec.label : "Macro ×\(params.count)"
    }

    var macroReadout: String {
        let params = macroParams
        if params.count == 1, let first = params.first {
            return first.spec.format(value(first))
        }
        return params.map { $0.spec.short }.joined(separator: "+")
    }

    // MARK: - Bulk operations

    func resetParameters() {
        for param in ParamID.allCases where param != .position {
            values[param] = param.spec.defaultValue
        }
    }

    func randomise(amount: Double = 1.0) {
        for param in ParamID.allCases where param.spec.randomisable {
            let spec = param.spec
            let target = Double.random(in: 0...1)
            let blended = normalized(param) + (target - normalized(param)) * amount.clamped(0, 1)
            values[param] = spec.value(fromNormalized: blended)
        }
    }

    // MARK: - Persistence

    func snapshot() -> ProjectSnapshot.TrackSnapshot {
        ProjectSnapshot.TrackSnapshot(
            samplePath: sampleURL?.path,
            sampleBookmark: try? sampleURL?.bookmarkData(),
            sampleName: sampleName,
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
            mute: mute,
            solo: solo,
            activeMacros: activeMacros.map(\.rawValue),
            grainShape: grainShape.rawValue
        )
    }

    /// Restores everything except the scrub head, which always returns to zero
    /// so the app agrees with a fader sitting at the bottom.
    func apply(_ snapshot: ProjectSnapshot.TrackSnapshot, version: Int) {
        pendingScatterSeconds = nil
        for (key, value) in snapshot.values {
            guard let param = ParamID(rawValue: key), param != .position else { continue }
            values[param] = value.clamped(param.spec.min, param.spec.max)
        }
        values[.position] = 0

        // Pre-v2 Scatter is a number of seconds; hold it until the sample
        // reports its length, then express it as the same span of audio.
        // Only when the project actually has a sample here: otherwise the
        // pending value would sit around and hijack the next sample loaded into
        // an empty strip, long after the project was restored.
        if version < 2, snapshot.samplePath != nil,
           let seconds = snapshot.values[ParamID.jitter.rawValue] {
            pendingScatterSeconds = seconds
            values[.jitter] = ParamID.jitter.spec.defaultValue
        }

        mute = snapshot.mute
        solo = snapshot.solo
        activeMacros = Set(snapshot.activeMacros.compactMap(MacroSlot.init(rawValue:)))
        grainShape = GranolaEngine.GrainShape(rawValue: snapshot.grainShape) ?? .gaussian
    }
}
