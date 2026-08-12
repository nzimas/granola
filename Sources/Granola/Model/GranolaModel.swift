import Foundation
import Combine
import SwiftUI

/// The application's single source of truth.
///
/// Every mutation funnels through here rather than being applied to
/// `TrackModel` directly. That is deliberate: one path to change a value means
/// one place that pushes it to the audio server and one place that reflects it
/// back to the controller's LEDs, so the hardware and the UI cannot drift apart.
@MainActor
final class GranolaModel: ObservableObject {

    static let trackCount = GranolaEngine.trackCount

    /// One engine per process. The app delegate and the SwiftUI scene both need
    /// to reach it, and two instances would race for the same audio device.
    static let shared = GranolaModel()

    // MARK: - Sub-models

    let tracks: [TrackModel]
    let mixer = SMCMixer()
    let pads = PadController()
    let catalog = AirwindowsCatalog()
    /// Four chain slots — the bottom row of the pad grid.
    let fxSlots: [FXSlot] = (0..<4).map(FXSlot.init(index:))

    private let server = SCServer()
    private let engine: GranolaEngine

    // MARK: - Published state

    @Published private(set) var serverState: SCServer.State = .stopped
    @Published private(set) var statusText = "Starting audio engine…"
    @Published private(set) var log: [String] = []

    @Published var masterLevel: Double = 0.8 {
        didSet { engine.setMasterLevel(masterLevel) }
    }
    // MARK: - Master effects
    //
    // Defaults are chosen to be immediately usable and clearly audible the
    // moment a send is raised — a long-but-not-endless plate, and a stereo
    // delay with a musical bounce. Track sends themselves start at zero.

    @Published var reverbDecay: Double = 3.5 { didSet { pushReverb() } }
    @Published var reverbSize: Double = 1.6 { didSet { pushReverb() } }
    @Published var reverbDamp: Double = 0.35 { didSet { pushReverb() } }
    @Published var reverbPredelay: Double = 0.025 { didSet { pushReverb() } }
    @Published var reverbModDepth: Double = 0.12 { didSet { pushReverb() } }
    @Published var reverbHighMult: Double = 0.55 { didSet { pushReverb() } }
    @Published var reverbWidth: Double = 1.0 { didSet { pushReverb() } }
    @Published var reverbLevel: Double = 1.0 { didSet { pushReverb() } }

    @Published var delayTimeL: Double = 0.375 { didSet { pushDelay() } }
    @Published var delayTimeR: Double = 0.5 { didSet { pushDelay() } }
    @Published var delayFeedback: Double = 0.45 { didSet { pushDelay() } }
    @Published var delayCrossFeed: Double = 0.35 { didSet { pushDelay() } }
    @Published var delayDamp: Double = 6500 { didSet { pushDelay() } }
    @Published var delayDiffusion: Double = 0.0 { didSet { pushDelay() } }
    @Published var delayModDepth: Double = 0.15 { didSet { pushDelay() } }
    @Published var delayWidth: Double = 1.0 { didSet { pushDelay() } }
    @Published var delayFreeze: Bool = false { didSet { pushDelay() } }
    @Published var delayLevel: Double = 1.0 { didSet { pushDelay() } }

    /// Longest delay the SynthDef allocates for. Changing this means changing
    /// `DelayC`'s maxdelaytime in Scripts/synthdefs.scd too.
    static let maxDelayTime: Double = 10.0

    /// Separate object: republishing the app model would re-render every strip.
    let masterMeter = StereoMeter()

    /// What the eight encoders are currently holding.
    ///
    /// The strip macro buttons keep their own state while a global mode is
    /// engaged, so leaving volume or pan hands the encoders straight back to
    /// whatever they were editing before.
    enum EncoderMode: Equatable {
        case macro
        case volume
        case pan
        case delaySend
        case reverbSend

        var label: String {
            switch self {
            case .macro: return "Macro"
            case .volume: return "Volume"
            case .pan: return "Pan"
            case .delaySend: return "Delay Send"
            case .reverbSend: return "Reverb Send"
            }
        }

        /// The parameter this mode drives, or nil for macro, which is
        /// per-track and decided by the strip buttons.
        var param: ParamID? {
            switch self {
            case .macro: return nil
            case .volume: return .level
            case .pan: return .pan
            case .delaySend: return .delaySend
            case .reverbSend: return .reverbSend
            }
        }
    }

    @Published private(set) var encoderMode: EncoderMode = .macro

    /// Volume and pan are selectors: engaging one leaves the other, and
    /// pressing the lit one returns the encoders to the macro buttons.
    func setEncoderMode(_ mode: EncoderMode) {
        encoderMode = (encoderMode == mode) ? .macro : mode
        refreshGlobalLEDs()
    }

    /// True when any track has a live voice. Published so the app's transport
    /// button tracks the controller's.
    @Published private(set) var isPlaying = false

    @Published var selectedTrack: Int = 0
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?

    /// A transient line shown in the header — load errors, recording paths,
    /// hardware hints.
    @Published var notice: String?

    // MARK: - Init

    init() {
        tracks = (0..<Self.trackCount).map(TrackModel.init(index:))
        engine = GranolaEngine(server: server)

        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleServerState(state) }
        }
        server.onLog = { [weak self] line in
            Task { @MainActor in
                self?.log.append(line)
                if let count = self?.log.count, count > 400 { self?.log.removeFirst(count - 400) }
            }
        }
        engine.onTrackMeter = { [weak self] index, amplitude in
            Task { @MainActor in
                guard let self, self.tracks.indices.contains(index) else { return }
                self.tracks[index].meter.level = amplitude
            }
        }
        engine.onMasterMeter = { [weak self] left, right in
            Task { @MainActor in
                self?.masterMeter.left = left
                self?.masterMeter.right = right
            }
        }

        wireMixer()
        wirePads()
        refreshOccupiedSlots()
    }

    // MARK: - Lifecycle

    func start() {
        server.boot { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.engine.buildGraph()
                    self.pushAllParameters()
                    self.pushReverb()
                    self.pushDelay()
                    self.engine.setMasterLevel(self.masterLevel)
                    self.reloadSamplesAfterBoot()
                    self.restorePerformanceFX()
                    self.refreshAllLEDs()
                }
            }
        }
        mixer.start()
        pads.start()
    }

    /// Tears the server down and boots it again — the recovery path when the
    /// audio device was busy or changed underneath us.
    func restartEngine() {
        server.shutdown()
        for track in tracks { track.playing = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start()
        }
    }

    func shutdown() {
        if isRecording { stopRecording() }
        mixer.stop()
        pads.stop()
        server.shutdown()
    }

    /// Server-side buffers do not survive a restart, so anything a track had
    /// loaded is read in again.
    private func reloadSamplesAfterBoot() {
        for (index, track) in tracks.enumerated() {
            guard let url = track.sampleURL else { continue }
            loadSample(url, into: index)
        }
    }

    private func handleServerState(_ state: SCServer.State) {
        serverState = state
        switch state {
        case .stopped: statusText = "Audio engine stopped"
        case .booting: statusText = "Starting audio engine…"
        case .running: statusText = "Audio engine running"
        case .failed(let reason): statusText = reason
        }
    }

    var isRunning: Bool { serverState == .running }

    // MARK: - Parameters

    func setParameter(_ track: Int, _ param: ParamID, value: Double) {
        guard tracks.indices.contains(track) else { return }
        let model = tracks[track]
        guard model.setValue(param, value) else { return }

        engine.set(track: track, param: param, value: model.value(param))

        // Reflect app-side scrub changes onto the fader null indicator so the
        // user can see where the physical fader has to go to regain control.
        if param == .position { mixer.setTrackVolume(track, value: model.value(.position)) }
    }

    func setNormalized(_ track: Int, _ param: ParamID, _ t: Double) {
        setParameter(track, param, value: param.spec.value(fromNormalized: t))
    }

    func binding(_ track: Int, _ param: ParamID) -> Binding<Double> {
        Binding(
            get: { self.tracks[track].value(param) },
            set: { self.setParameter(track, param, value: $0) }
        )
    }

    /// Every encoder turn — hardware or on-screen — arrives here, and the
    /// current mode decides what it moves.
    func nudgeEncoder(_ track: Int, byTicks ticks: Int) {
        // Shift turns every encoder into that track's filter, whatever the
        // selectors are set to — a momentary override, so it is always one
        // gesture away without costing a selector button.
        if shiftHeld {
            // Coarser than the other encoder targets on purpose: this is a
            // grab-and-sweep gesture, and at the standard step it took the
            // better part of three revolutions to reach either stop.
            nudgeSingle(track, .filter, byTicks: ticks, centreDetent: true, scale: 2.6)
            // Hand the strip's readout to the filter for the rest of the hold.
            tracks[track].showingFilter = true
            return
        }
        guard let param = encoderMode.param else {
            nudgeMacro(track, byTicks: ticks)
            return
        }
        nudgeSingle(track, param, byTicks: ticks, centreDetent: param == .pan)
    }

    private func nudgeSingle(_ track: Int, _ param: ParamID, byTicks ticks: Int,
                             centreDetent: Bool = false, scale: Double = 1) {
        guard tracks.indices.contains(track) else { return }
        let model = tracks[track]
        let current = model.normalized(param)
        var target = current + encoderDelta(ticks) * scale

        if centreDetent {
            // Catch centre only when the move passes THROUGH it. A detent
            // defined as "within X of centre" is wider than a single encoder
            // tick, so it swallows every tick and the knob appears dead.
            let centre = param.spec.normalized(fromValue: 0)
            if (current - centre) * (target - centre) < 0 { target = centre }
        }

        guard model.setNormalized(param, target) else { return }
        engine.set(track: track, param: param, value: model.value(param))
    }

    /// Larger sweeps for faster spins, without losing fine control.
    private func encoderDelta(_ ticks: Int) -> Double {
        let magnitude = Double(abs(ticks))
        return Double(ticks.signum()) * 0.004 * magnitude * (1 + magnitude * 0.35)
    }

    /// Applies a relative move to whichever parameters this track's macro
    /// buttons have selected. One OSC message carries the whole group.
    func nudgeMacro(_ track: Int, byTicks ticks: Int) {
        guard tracks.indices.contains(track) else { return }
        let model = tracks[track]
        let params = model.macroParams
        guard !params.isEmpty else { return }

        let delta = encoderDelta(ticks)
        var changed: [(ParamID, Double)] = []
        for param in params where model.nudgeNormalized(param, by: delta) {
            changed.append((param, model.value(param)))
        }
        guard !changed.isEmpty else { return }
        engine.set(track: track, values: changed)
    }

    func toggleMacro(_ track: Int, _ slot: MacroSlot) {
        guard tracks.indices.contains(track) else { return }
        tracks[track].toggleMacro(slot)
        refreshTrackLEDs(track)
    }

    /// The shape row is a global timbral switch: one row of four pads for
    /// eight tracks, so it applies to all of them. Per-track shapes remain
    /// available in the app's track panel.
    @Published private(set) var globalGrainShape: GranolaEngine.GrainShape = .gaussian

    func setGrainShapeForAll(_ shape: GranolaEngine.GrainShape) {
        globalGrainShape = shape
        for index in tracks.indices { setGrainShape(index, shape) }
        notice = "Grain envelope: \(shape.label)"
    }

    func setGrainShape(_ track: Int, _ shape: GranolaEngine.GrainShape) {
        guard tracks.indices.contains(track) else { return }
        tracks[track].grainShape = shape
        engine.setGrainShape(track: track, shape: shape)
    }

    private func pushAllParameters() {
        for (index, track) in tracks.enumerated() {
            engine.set(track: index, values: ParamID.allCases.map { ($0, track.value($0)) })
            engine.setMuted(track: index, muted: effectiveMute(index))
        }
    }

    private func pushReverb() {
        engine.setReverb([
            ("decay", reverbDecay), ("size", reverbSize), ("damp", reverbDamp),
            ("predelay", reverbPredelay), ("modDepth", reverbModDepth),
            ("highMult", reverbHighMult), ("width", reverbWidth), ("amp", reverbLevel)
        ])
    }

    private func pushDelay() {
        engine.setDelay([
            ("timeL", delayTimeL), ("timeR", delayTimeR),
            ("feedback", delayFeedback), ("crossFeed", delayCrossFeed),
            ("damp", delayDamp), ("diffusion", delayDiffusion),
            ("modDepth", delayModDepth), ("width", delayWidth),
            ("freeze", delayFreeze ? 1 : 0), ("amp", delayLevel)
        ])
    }

    /// Ping-pong is just full cross-feed; exposed as a one-press shortcut.
    func setPingPong(_ on: Bool) {
        delayCrossFeed = on ? 1.0 : 0.0
    }

    // MARK: - Mute / solo

    /// Any solo anywhere mutes every non-soloed track — the usual mixer rule.
    private func effectiveMute(_ index: Int) -> Bool {
        let anySolo = tracks.contains { $0.solo }
        let track = tracks[index]
        return track.mute || (anySolo && !track.solo)
    }

    func toggleMute(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        tracks[index].mute.toggle()
        refreshMuteState()
    }

    func toggleSolo(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        tracks[index].solo.toggle()
        refreshMuteState()
    }

    private func refreshMuteState() {
        for index in tracks.indices {
            engine.setMuted(track: index, muted: effectiveMute(index))
        }
    }

    // MARK: - Samples

    func loadSample(_ url: URL, into index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        track.isLoading = true
        track.loadError = nil

        Task.detached(priority: .userInitiated) {
            do {
                let loaded = try SampleLoader.load(url)
                await MainActor.run {
                    self.applyLoadedSample(loaded, to: index)
                }
            } catch {
                await MainActor.run {
                    track.isLoading = false
                    track.loadError = error.localizedDescription
                    self.notice = error.localizedDescription
                }
            }
        }
    }

    private func applyLoadedSample(_ sample: SampleLoader.Loaded, to index: Int) {
        let track = tracks[index]
        track.sampleURL = sample.originalURL
        track.sampleName = sample.originalURL.deletingPathExtension().lastPathComponent
        track.duration = sample.duration
        track.channels = sample.channels

        // Finish the pre-v2 Scatter conversion now that there is a duration to
        // measure those seconds against.
        if let seconds = track.pendingScatterSeconds, sample.duration > 0 {
            track.pendingScatterSeconds = nil
            track.setValue(.jitter, (seconds / sample.duration * 100).clamped(0, 100))
        }
        track.waveform = sample.waveform
        track.extraChannelsIgnored = max(0, sample.channels - 2)

        if track.extraChannelsIgnored > 0 {
            notice = "“\(track.sampleName)” has \(sample.channels) channels — granulating the first stereo pair."
        }

        engine.loadSample(track: index, sample: sample) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                track.isLoading = false
                guard ok else {
                    track.loadError = "The audio engine could not load this file."
                    self.notice = track.loadError
                    return
                }
                self.startTrack(index, channels: sample.channels)
            }
        }
    }

    private func startTrack(_ index: Int, channels: Int) {
        let track = tracks[index]
        engine.startVoice(
            track: index,
            channels: channels,
            parameters: Dictionary(uniqueKeysWithValues: ParamID.allCases.map { ($0, track.value($0)) }),
            grainShape: track.grainShape
        )
        track.playing = true
        engine.setMuted(track: index, muted: effectiveMute(index))
        // Samples load asynchronously, so this is the first moment the machine
        // is genuinely playing. Without it the surface stays on STOP after a
        // project load, because the refresh ran before any voice existed.
        refreshGlobalLEDs()
    }

    func clearSample(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        engine.freeVoice(track: index)
        track.playing = false
        track.sampleURL = nil
        track.sampleName = "—"
        track.duration = 0
        track.waveform = []
        refreshGlobalLEDs()
    }

    // MARK: - Transport

    /// Play is one latching button now, so it has to do both jobs.
    func toggleTransport() {
        if isPlaying { stopAll() } else { playAll() }
    }

    func playAll() {
        for (index, track) in tracks.enumerated() where track.hasSample && !track.playing {
            restart(index)
        }
        refreshGlobalLEDs()
    }

    func stopAll() {
        for (index, track) in tracks.enumerated() where track.playing {
            engine.freeVoice(track: index)
            track.playing = false
        }
        refreshGlobalLEDs()
    }

    func restart(_ index: Int) {
        guard tracks.indices.contains(index), tracks[index].hasSample else { return }
        startTrack(index, channels: tracks[index].channels)
    }

    func rewindAll() {
        for index in tracks.indices { setParameter(index, .position, value: 0) }
    }

    func scatter() {
        for index in tracks.indices where tracks[index].hasSample {
            setParameter(index, .position, value: Double.random(in: 0...1))
        }
    }

    func randomiseSelected() {
        let targets = tracks.contains(where: \.armed)
            ? tracks.indices.filter { tracks[$0].armed }
            : [selectedTrack]
        for index in targets {
            tracks[index].randomise()
            engine.set(track: index, values: ParamID.allCases.map { ($0, tracks[index].value($0)) })
        }
    }

    func resetSelected() {
        tracks[selectedTrack].resetParameters()
        engine.set(track: selectedTrack,
                   values: ParamID.allCases.map { ($0, tracks[selectedTrack].value($0)) })
    }

    func selectTrack(_ index: Int) {
        guard tracks.indices.contains(index) else { return }
        selectedTrack = index
        for (i, track) in tracks.enumerated() { track.selected = (i == index) }
    }

    func panic() {
        engine.panic()
        for track in tracks { track.playing = false }
        refreshGlobalLEDs()
    }

    // MARK: - Performance FX

    /// How long a chain takes to fade in when a slot is engaged, and out when
    /// it is released. A performance control wants to swell rather than snap.
    /// App-only: the controllers are performance tools, not config surfaces.
    @Published var fxFadeTime: Double = 5.0

    /// Wet blend a freshly assembled link is given. 40% transforms audibly
    /// without smothering the source.
    @Published var fxWetMix: Double = 0.4

    /// Per-link automatic gain matching, on by default.
    @Published var fxAutoGain: Bool = true {
        didSet {
            for slot in fxSlots where slot.isActive {
                for link in slot.chain {
                    engine.setEffectControl(node: link.node, key: "autoGain",
                                            value: fxAutoGain ? 1 : 0)
                }
            }
            engine.setChainAutoGain(fxAutoGain)
        }
    }

    /// Which tracks are routed through the performance chain (top two pad rows).
    @Published private(set) var fxTracks = Set<Int>()
    /// Activation order, so the chain reflects the order pads were pressed.
    private var fxActivationCounter = 0
    @Published private(set) var fxChainSummary: String = "no chain"

    private func wirePads() {
        pads.onPad = { [weak self] pad, isOn in
            guard let self else { return }
            if let slot = PadController.fxSlot(forPad: pad) {
                self.setFXSlot(slot, active: isOn)
            } else if let shape = PadController.grainShape(forPad: pad) {
                // The four shapes are mutually exclusive, but the pads latch
                // independently in hardware and cannot be told otherwise. So a
                // pad turning ON selects that shape and a pad turning off is
                // ignored: the last one pressed wins, which is what the gesture
                // means even when several pads are lit.
                if isOn { self.setGrainShapeForAll(shape) }
            } else if let track = PadController.trackIndex(forPad: pad) {
                self.setTrackThroughFX(track, enabled: isOn)
            }
        }
    }

    /// Toggling a slot on assembles a brand-new random chain for it; toggling
    /// off frees that slot's links and lets the rest of the chain close up.
    func setFXSlot(_ index: Int, active: Bool) {
        guard fxSlots.indices.contains(index) else { return }
        let slot = fxSlots[index]
        guard slot.isActive != active else { return }
        slot.isActive = active

        if active {
            fxActivationCounter += 1
            slot.activationOrder = fxActivationCounter
            slot.chain = assembleChain()
            for position in slot.chain.indices {
                slot.chain[position].node = engine.addEffect(
                    slot.chain[position], fade: fxFadeTime, autoGain: fxAutoGain)
            }
            notice = "Slot \(index + 1): \(slot.label)"
        } else {
            for link in slot.chain { engine.removeEffect(node: link.node, fade: fxFadeTime) }
            slot.chain = []
            slot.activationOrder = 0
        }
        updateChainSummary()
    }

    /// Re-rolls a slot that is already running, without disturbing the others.
    func rerollFXSlot(_ index: Int) {
        guard fxSlots.indices.contains(index), fxSlots[index].isActive else { return }
        setFXSlot(index, active: false)
        setFXSlot(index, active: true)
    }

    private func assembleChain() -> [FXInstance] {
        guard !catalog.isEmpty else { return [] }
        var generator = SystemRandomNumberGenerator()
        let length = Int.random(in: 1...4, using: &generator)
        var chain: [FXInstance] = []
        var used = Set<String>()
        while chain.count < length {
            guard let candidate = catalog.randomInstance(mixCentre: fxWetMix,
                                                        using: &generator) else { break }
            // Two of the same effect back to back is rarely interesting.
            if used.contains(candidate.effect.name) { continue }
            used.insert(candidate.effect.name)
            chain.append(candidate)
        }
        return chain
    }

    private func updateChainSummary() {
        let active = fxSlots.filter(\.isActive).sorted { $0.activationOrder < $1.activationOrder }
        let names = active.flatMap { $0.chain.map(\.effect.name) }
        fxChainSummary = names.isEmpty ? "no chain" : names.joined(separator: " → ")
    }

    /// The whole composite chain, in signal order.
    var activeChain: [(slot: Int, link: FXInstance)] {
        fxSlots.filter(\.isActive)
            .sorted { $0.activationOrder < $1.activationOrder }
            .flatMap { slot in slot.chain.map { (slot.index, $0) } }
    }

    func setTrackThroughFX(_ track: Int, enabled: Bool) {
        guard tracks.indices.contains(track) else { return }
        if enabled { fxTracks.insert(track) } else { fxTracks.remove(track) }
        engine.setTrackRouting(track: track, throughPerformance: enabled)
    }

    func setEffectParam(slot: Int, link: UUID, index: Int, value: Double) {
        guard fxSlots.indices.contains(slot),
              let position = fxSlots[slot].chain.firstIndex(where: { $0.id == link })
        else { return }
        fxSlots[slot].chain[position].params[index] = value
        engine.setEffectParam(node: fxSlots[slot].chain[position].node, index: index, value: value)
    }

    func setEffectMix(slot: Int, link: UUID, value: Double) {
        guard fxSlots.indices.contains(slot),
              let position = fxSlots[slot].chain.firstIndex(where: { $0.id == link })
        else { return }
        fxSlots[slot].chain[position].mix = value
        engine.setEffectControl(node: fxSlots[slot].chain[position].node, key: "mix", value: value)
    }

    /// Re-applies routing and rebuilds any running chain after a server restart.
    private func restorePerformanceFX() {
        for track in fxTracks { engine.setTrackRouting(track: track, throughPerformance: true) }
        for slot in fxSlots where slot.isActive {
            for position in slot.chain.indices {
                slot.chain[position].node = engine.addEffect(
                    slot.chain[position], fade: fxFadeTime, autoGain: fxAutoGain)
            }
        }
    }

    // MARK: - Projects

    let projects = ProjectStore()

    /// Mirrors which slots hold a project, so views and LED refreshes do not
    /// touch the disk.
    @Published private(set) var occupiedSlots: [Bool] =
        Array(repeating: false, count: ProjectStore.slotCount)

    /// Where the state on screen came from. Set by both load and save — saving
    /// to a slot makes that slot the one you are working in — and cleared if
    /// that slot is wiped. Nil after a fresh start or a clear, when the current
    /// state belongs to no slot.
    @Published private(set) var currentProjectSlot: Int?

    /// Toggled on and off a few times right after a save so the slot visibly
    /// blinks. Writing a project is fast enough to be invisible otherwise, and
    /// a save with no acknowledgement is indistinguishable from a missed press.
    @Published private(set) var savingSlot: Int?

    private var saveBlinkWork: [DispatchWorkItem] = []

    /// Two on/off pulses, no view-side animation: a crisp blink reads as
    /// "written", where a smooth fade reads as decoration.
    private func blinkSavedSlot(_ slot: Int) {
        saveBlinkWork.forEach { $0.cancel() }
        saveBlinkWork.removeAll()
        savingSlot = slot

        for (delay, on) in [(0.11, false), (0.22, true), (0.36, false)] {
            let work = DispatchWorkItem { [weak self] in
                self?.savingSlot = on ? slot : nil
            }
            saveBlinkWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// True while the surface is showing project slots instead of its normal
    /// functions. Entering it repaints every LED.
    @Published private(set) var projectLayerActive = false {
        didSet { refreshAllLEDs() }
    }

    func setProjectLayer(_ active: Bool) {
        guard projectLayerActive != active else { return }
        projectLayerActive = active
        notice = active
            ? "Project slots 1-9: tap to load, hold to save — shift+play to close"
            : nil
    }

    func toggleProjectLayer() { setProjectLayer(!projectLayerActive) }

    private func refreshOccupiedSlots() {
        occupiedSlots = (0..<ProjectStore.slotCount).map { projects.isOccupied($0) }
    }

    func snapshot(named name: String) -> ProjectSnapshot {
        ProjectSnapshot(
            name: name,
            savedAt: Date(),
            tracks: tracks.map { $0.snapshot() },
            master: ProjectSnapshot.MasterSnapshot(
                level: masterLevel,
                reverbDecay: reverbDecay, reverbSize: reverbSize, reverbDamp: reverbDamp,
                reverbPredelay: reverbPredelay, reverbModDepth: reverbModDepth,
                reverbHighMult: reverbHighMult, reverbWidth: reverbWidth, reverbLevel: reverbLevel,
                delayTimeL: delayTimeL, delayTimeR: delayTimeR,
                delayFeedback: delayFeedback, delayCrossFeed: delayCrossFeed,
                delayDamp: delayDamp, delayDiffusion: delayDiffusion,
                delayModDepth: delayModDepth, delayWidth: delayWidth,
                delayFreeze: delayFreeze, delayLevel: delayLevel
            )
        )
    }

    func saveProject(to slot: Int) {
        guard (0..<ProjectStore.slotCount).contains(slot) else { return }
        let snapshot = snapshot(named: "Project \(slot + 1)")
        do {
            try projects.save(snapshot, to: slot)
            refreshOccupiedSlots()
            currentProjectSlot = slot
            blinkSavedSlot(slot)
            notice = "Saved project \(slot + 1) — \(snapshot.loadedTrackCount) track(s)"
        } catch {
            notice = "Could not save project \(slot + 1): \(error.localizedDescription)"
        }
        refreshAllLEDs()
    }

    func loadProject(from slot: Int) {
        guard let snapshot = projects.load(slot) else {
            notice = "Project slot \(slot + 1) is empty"
            return
        }

        // Master and effects first, so anything that starts playing during the
        // sample reload is already going through the right chain.
        let master = snapshot.master
        masterLevel = master.level
        reverbDecay = master.reverbDecay
        reverbSize = master.reverbSize
        reverbDamp = master.reverbDamp
        reverbPredelay = master.reverbPredelay
        reverbModDepth = master.reverbModDepth
        reverbHighMult = master.reverbHighMult
        reverbWidth = master.reverbWidth
        reverbLevel = master.reverbLevel
        delayTimeL = master.delayTimeL
        delayTimeR = master.delayTimeR
        delayFeedback = master.delayFeedback
        delayCrossFeed = master.delayCrossFeed
        delayDamp = master.delayDamp
        delayDiffusion = master.delayDiffusion
        delayModDepth = master.delayModDepth
        delayWidth = master.delayWidth
        delayFreeze = master.delayFreeze
        delayLevel = master.delayLevel

        var missing: [String] = []

        for (index, track) in tracks.enumerated() {
            guard index < snapshot.tracks.count else { continue }
            let stored = snapshot.tracks[index]

            engine.freeVoice(track: index)
            track.playing = false
            track.apply(stored, version: snapshot.version)
            track.loadError = nil

            if let path = stored.samplePath {
                let url = resolveSample(path: path, bookmark: stored.sampleBookmark)
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    // Parameters are already in place, so the voice starts with
                    // the project's settings rather than defaults.
                    loadSample(url, into: index)
                } else {
                    missing.append((path as NSString).lastPathComponent)
                    clearSampleMetadata(index)
                    track.loadError = "Missing: \(path)"
                }
            } else {
                clearSampleMetadata(index)
            }
        }

        pushAllParameters()
        refreshMuteState()
        currentProjectSlot = slot

        // Every scrub head is at zero and the app says so, which makes the
        // fader null LEDs flash until the performer pulls the faders down.
        for index in tracks.indices {
            mixer.setTrackVolume(index, value: 0)
        }

        setProjectLayer(false)
        refreshAllLEDs()

        notice = missing.isEmpty
            ? "Loaded project \(slot + 1) — faders to the bottom"
            : "Loaded project \(slot + 1); missing \(missing.count) sample(s): \(missing.joined(separator: ", "))"
    }

    /// Prefers the bookmark so a project still opens after its samples move,
    /// and falls back to the recorded path.
    private func resolveSample(path: String, bookmark: Data?) -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(fileURLWithPath: path)
    }

    private func clearSampleMetadata(_ index: Int) {
        let track = tracks[index]
        track.sampleURL = nil
        track.sampleName = "—"
        track.duration = 0
        track.waveform = []
    }

    func clearProject(slot: Int) {
        projects.clear(slot)
        refreshOccupiedSlots()
        if currentProjectSlot == slot { currentProjectSlot = nil }
        refreshAllLEDs()
        notice = "Cleared project slot \(slot + 1)"
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Records the master output. With no URL, a timestamped file lands in
    /// ~/Music/Granola.
    func startRecording(to destination: URL? = nil, completion: ((Bool) -> Void)? = nil) {
        let url = destination ?? defaultRecordingURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        engine.startRecording(to: url) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = ok
                self.lastRecordingURL = ok ? url : nil
                self.notice = ok ? "Recording to \(url.path)" : "Could not start recording."
                self.refreshGlobalLEDs()
                completion?(ok)
            }
        }
    }

    private func defaultRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let directory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory
            .appendingPathComponent("Granola", isDirectory: true)
            .appendingPathComponent("Granola-\(formatter.string(from: Date())).wav")
    }

    func stopRecording() {
        engine.stopRecording()
        isRecording = false
        if let url = lastRecordingURL { notice = "Saved \(url.lastPathComponent)" }
        refreshGlobalLEDs()
    }

    // MARK: - Controller

    private func wireMixer() {
        mixer.onFader = { [weak self] index, value in
            guard let self, self.tracks.indices.contains(index) else { return }
            // The fader is the scrub head. It writes straight to position and
            // deliberately does not echo back to the null LED — the hardware
            // and the app already agree when the move came from the fader.
            let model = self.tracks[index]
            guard model.setValue(.position, value) else { return }
            self.engineSetPosition(index, model.value(.position))
        }

        mixer.onEncoder = { [weak self] index, delta in
            self?.nudgeEncoder(index, byTicks: delta)
        }

        mixer.onButton = { [weak self] button, pressed in
            self?.handleButton(button, pressed: pressed)
        }
    }

    private func engineSetPosition(_ index: Int, _ value: Double) {
        engine.set(track: index, param: .position, value: value)
    }

    // MARK: - The bottom row
    //
    // None of these buttons does what the device's printed legend says, apart
    // from Play. The legends are recorded only so the physical button can be
    // identified; position is what matters.
    //
    // This table is the single source of truth: the press handler, the LED
    // refresh and the app's on-screen row all read it, so the surface and the
    // window cannot drift apart. Reassigning a button is one row.

    struct GlobalButton {
        let position: Int                 // 1-11, left to right
        let button: SMCMixer.Button
        let legend: String                // printed on the device; means nothing
        let name: String                  // what it does in Granola
        /// Buttons 1-5 latch in the device's firmware; 6-11 are momentary and
        /// their LEDs cannot be held on.
        let latches: Bool
        let action: ((GranolaModel) -> Void)?
        let lit: ((GranolaModel) -> Bool)?
    }

    static let globalRow: [GlobalButton] = [
        GlobalButton(position: 1, button: .play, legend: "Play", name: "PLAY / STOP",
                     latches: true,
                     action: { $0.toggleTransport() }, lit: { $0.isPlaying }),
        GlobalButton(position: 2, button: .stop, legend: "Stop", name: "VOL",
                     latches: true,
                     action: { $0.setEncoderMode(.volume) },
                     lit: { $0.encoderMode == .volume }),
        GlobalButton(position: 3, button: .record, legend: "Record", name: "PAN",
                     latches: true,
                     action: { $0.setEncoderMode(.pan) },
                     lit: { $0.encoderMode == .pan }),
        GlobalButton(position: 4, button: .rewind, legend: "Rewind", name: "DLY",
                     latches: true,
                     action: { $0.setEncoderMode(.delaySend) },
                     lit: { $0.encoderMode == .delaySend }),
        GlobalButton(position: 5, button: .fastForward, legend: "Fast Fwd", name: "RVB",
                     latches: true,
                     action: { $0.setEncoderMode(.reverbSend) },
                     lit: { $0.encoderMode == .reverbSend }),
        GlobalButton(position: 6, button: .bankLeft, legend: "Bank Left", name: "SCATTER",
                     latches: false,
                     action: { $0.scatter() }, lit: nil),
        GlobalButton(position: 7, button: .bankRight, legend: "Bank Right", name: "TRACK ▶",
                     latches: false,
                     action: { $0.selectTrack(min(trackCount - 1, $0.selectedTrack + 1)) },
                     lit: nil),
        GlobalButton(position: 8, button: .cursorUp, legend: "Cursor Up", name: "RANDOM",
                     latches: false,
                     action: { $0.randomiseSelected() }, lit: nil),
        GlobalButton(position: 9, button: .cursorDown, legend: "Cursor Down", name: "RESET",
                     latches: false,
                     action: { $0.resetSelected() }, lit: nil),
        GlobalButton(position: 10, button: .cursorLeft, legend: "Cursor Left", name: "◀ TRACK",
                     latches: false,
                     action: { $0.selectTrack(max(0, $0.selectedTrack - 1)) }, lit: nil),
        // The modifier. No action of its own, in either direction.
        GlobalButton(position: 11, button: .cursorRight, legend: "Cursor Right", name: "SHIFT",
                     latches: false, action: nil, lit: nil)
    ]

    static func globalButton(for button: SMCMixer.Button) -> GlobalButton? {
        globalRow.first { $0.button == button }
    }

    /// Stand-in for the Shift key.
    ///
    /// The device's real Shift transmits nothing at all — it does not even let
    /// the button pressed with it through — so it cannot be a modifier. The
    /// rightmost button on the bottom row takes the job instead. It is
    /// momentary, which is what a held modifier needs.
    static let shiftButton: SMCMixer.Button = .cursorRight

    /// Nine project slots: buttons 2 to 10, in physical order.
    ///
    /// Button 11 is deliberately absent. It is the shift modifier, and a
    /// modifier cannot also be a slot: holding it to save would be
    /// indistinguishable from holding it to shift, so that slot could be
    /// loaded but never written.
    static let projectSlotButtons: [SMCMixer.Button] = [
        .stop, .record, .rewind, .fastForward, .bankLeft,
        .bankRight, .cursorUp, .cursorDown, .cursorLeft
    ]

    /// True while the shift stand-in is held.
    @Published private(set) var shiftHeld = false

    /// What a button does when shift is held. Returning nil means the button
    /// keeps its normal behaviour.
    private func shiftAction(for button: SMCMixer.Button) -> (() -> Void)? {
        switch button {
        case .play: return { [weak self] in self?.toggleProjectLayer() }
        default: return nil
        }
    }

    static let longPressThreshold: TimeInterval = 0.6

    /// Invalidates a pending long-press when the button is released first.
    private var pressGeneration: [SMCMixer.Button: Int] = [:]
    private var longPressFired: Set<SMCMixer.Button> = []

    private func slotIndex(for button: SMCMixer.Button) -> Int? {
        Self.projectSlotButtons.firstIndex(of: button)
    }

    /// What a button does when held past the threshold, or nil if it has no
    /// long-press meaning and should act the moment it is pressed.
    private func longPressAction(for button: SMCMixer.Button) -> (() -> Void)? {
        if projectLayerActive, let slot = slotIndex(for: button) {
            return { [weak self] in self?.saveProject(to: slot) }
        }
        return nil
    }

    // The project layer used to be entered with a Play+Stop chord. Stop is a
    // selector now, so the chord is impossible; Bank Right toggles it instead.

    private func handleButton(_ button: SMCMixer.Button, pressed: Bool) {
        // The shift stand-in is a modifier and nothing else, in every layer
        // and in both directions.
        if button == Self.shiftButton {
            shiftHeld = pressed
            // Releasing shift ends the filter readout everywhere — the gesture
            // is over, so the strips go back to their selectors.
            if !pressed {
                for track in tracks where track.showingFilter { track.showingFilter = false }
            }
            return
        }

        if pressed {
            let generation = (pressGeneration[button] ?? 0) + 1
            pressGeneration[button] = generation
            longPressFired.remove(button)

            guard let action = longPressAction(for: button) else {
                // No long-press meaning: respond immediately, as before.
                performShortPress(button)
                return
            }
            // Fire while the button is still held, so it feels like hardware
            // rather than waiting for the release.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressThreshold) { [weak self] in
                guard let self, self.pressGeneration[button] == generation else { return }
                self.longPressFired.insert(button)
                action()
            }
            return
        }

        // Release: invalidate any pending long-press, then treat as a tap if
        // the long-press had not already fired.
        pressGeneration[button] = (pressGeneration[button] ?? 0) + 1
        let fired = longPressFired.remove(button) != nil
        guard longPressAction(for: button) != nil || fired else { return }
        if !fired { performShortPress(button) }
    }

    /// Track buttons are repurposed as the four macro toggles, top to bottom:
    /// Mute→Grain Size, Solo→Density, Rec→Jitter, Select→Pitch. That matches
    /// the physical layout of the strip, which is not the Mackie order.
    private func performShortPress(_ button: SMCMixer.Button) {
        SMCMixer.log("ACT  short press \(button) (mode \(encoderMode.label), "
                     + "layer \(projectLayerActive), shift \(shiftHeld))")

        // Shift combinations take precedence over everything.
        if shiftHeld, let action = shiftAction(for: button) {
            action()
            return
        }

        // In the project layer the eight slot buttons load instead of doing
        // their normal jobs; everything else still works.
        if projectLayerActive, let slot = slotIndex(for: button) {
            loadProject(from: slot)
            return
        }

        switch button {
        case .mute(let n): toggleMacro(n, .grainSize); selectTrack(n)
        case .solo(let n): toggleMacro(n, .density); selectTrack(n)
        case .rec(let n): toggleMacro(n, .jitter); selectTrack(n)
        case .select(let n): toggleMacro(n, .pitch); selectTrack(n)

        default:
            // Everything on the bottom row comes from the table above.
            Self.globalButton(for: button)?.action?(self)
        }
        refreshGlobalLEDs()
    }

    func cycleGrainShapeForSelected(by step: Int) {
        let shapes = GranolaEngine.GrainShape.allCases
        let track = tracks[selectedTrack]
        let index = (shapes.firstIndex(of: track.grainShape) ?? 0)
        let next = shapes[((index + step) % shapes.count + shapes.count) % shapes.count]
        setGrainShape(selectedTrack, next)
        notice = "Track \(selectedTrack + 1) grain shape: \(next.label)"
    }

    // MARK: - LED feedback

    /// The controller keeps no state of its own in DAW mode, so the app has to
    /// assert every LED. Writes are diffed inside SMCMixer.
    func refreshAllLEDs() {
        guard projectLayerActive else {
            for index in tracks.indices { refreshTrackLEDs(index) }
            refreshGlobalLEDs()
            return
        }

        // In the project layer the surface shows one thing only: which slots
        // hold a project. Everything else goes dark so there is no ambiguity
        // about what a press will do — except Play/Stop, which keep showing
        // the transport state.
        for index in tracks.indices {
            mixer.setLED(.mute(index), on: false)
            mixer.setLED(.solo(index), on: false)
            mixer.setLED(.rec(index), on: false)
            mixer.setLED(.select(index), on: false)
        }
        mixer.setLED(.cursorLeft, on: false)

        for (slot, button) in Self.projectSlotButtons.enumerated() {
            mixer.setLED(button, on: occupiedSlots.indices.contains(slot) && occupiedSlots[slot])
        }

        updateTransportState()
        mixer.setLED(.play, on: isPlaying)
    }

    private func refreshTrackLEDs(_ index: Int) {
        let track = tracks[index]
        mixer.setLED(.mute(index), on: track.activeMacros.contains(.grainSize))
        mixer.setLED(.solo(index), on: track.activeMacros.contains(.density))
        mixer.setLED(.rec(index), on: track.activeMacros.contains(.jitter))
        mixer.setLED(.select(index), on: track.activeMacros.contains(.pitch))
    }

    private func refreshGlobalLEDs() {
        guard !projectLayerActive else { refreshAllLEDs(); return }
        updateTransportState()
        mixer.setLED(.play, on: isPlaying)
        mixer.setLED(.stop, on: !isPlaying)
        mixer.setLED(.stop, on: encoderMode == .volume)
        mixer.setLED(.record, on: encoderMode == .pan)
        mixer.setLED(.rewind, on: encoderMode == .delaySend)
        mixer.setLED(.fastForward, on: encoderMode == .reverbSend)
        mixer.setLED(.bankLeft, on: false)

        // Slot buttons with no job outside the project layer must be told to go
        // dark. Leaving them alone strands whatever the layer lit, which is the
        // controller and the app disagreeing.
        for button in [SMCMixer.Button.bankRight, .cursorUp, .cursorDown, .cursorLeft, .cursorRight] {
            mixer.setLED(button, on: false)
        }
    }

    /// Mirrors "is anything playing" into published state. `TrackModel.playing`
    /// lives on a separate object, so views observing the app model never see
    /// it change — this is what keeps the app's PLAY button in step with the
    /// controller's.
    private func updateTransportState() {
        let playing = tracks.contains { $0.playing }
        if isPlaying != playing { isPlaying = playing }
    }
}
