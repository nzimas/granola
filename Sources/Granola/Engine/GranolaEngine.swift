import Foundation

/// Translates the model into scsynth's world: buses, groups, buffers, nodes.
///
/// Node and bus numbers are fixed rather than allocated, which makes the whole
/// graph reproducible and lets any part of the app address a track's synth
/// without holding a reference to it.
final class GranolaEngine {

    static let trackCount = 8

    let server: SCServer

    // MARK: - Fixed graph addresses

    private enum Group {
        static let voices: Int32 = 10
        static let strips: Int32 = 11
        static let effects: Int32 = 12
        static let master: Int32 = 13
        /// The Airwindows chain runs AFTER the send effects, so it processes
        /// the reverb and delay tails as well as the routed dry tracks.
        static let performance: Int32 = 14
    }

    private enum Node {
        static func strip(_ track: Int) -> Int32 { 1100 + Int32(track) }
        static let reverb: Int32 = 1200
        static let delay: Int32 = 1250
        static let master: Int32 = 1300
        static let recorder: Int32 = 1400
        /// Permanently the head of the performance group.
        static let performanceIn: Int32 = 1490
        /// Permanently the tail of the performance group.
        static let performanceOut: Int32 = 1500
    }

    private enum Bus {
        static let mix: Int32 = 16
        static let reverb: Int32 = 18
        static let record: Int32 = 20
        static let delay: Int32 = 22
        static func track(_ index: Int) -> Int32 { 24 + Int32(index) * 2 }
        /// Tracks 0-7 occupy 24…39, so the performance bus starts after them.
        static let performance: Int32 = 40
        /// Control bus carrying the level entering the chain.
        static let chainLevel: Int32 = 8
    }

    private enum Buffer {
        static func left(_ track: Int) -> Int32 { Int32(track) * 2 }
        static func right(_ track: Int) -> Int32 { Int32(track) * 2 + 1 }
        static let grainEnvelopeBase: Int32 = 200
        static let recorder: Int32 = 300
    }

    // MARK: - Callbacks

    var onTrackMeter: ((Int, Double) -> Void)?
    var onMasterMeter: ((Double, Double) -> Void)?

    private var loadedTracks = Set<Int>()

    /// Live voice node per track.
    ///
    /// Voices must NOT use a fixed id. Freeing a voice starts a release
    /// envelope, so the old node is still alive for a moment; creating the
    /// replacement with the same id is rejected by the server as a duplicate
    /// and the track goes silent. Every voice therefore gets a fresh id.
    private var voiceNodes: [Int: Int32] = [:]
    private var nextVoiceNode: Int32 = 1000

    private func voiceNode(_ track: Int) -> Int32 { voiceNodes[track] ?? 0 }

    init(server: SCServer) {
        self.server = server
        server.addListener { [weak self] message in self?.handle(message) }
    }

    private func handle(_ message: OSCMessage) {
        switch message.address {
        case "/trackMeter":
            // SendReply payload: [nodeID, replyID, index, amplitude]
            guard message.arguments.count >= 4 else { return }
            let index = message.arguments[2].intValue
            let amplitude = Double(message.arguments[3].floatValue)
            onTrackMeter?(index, amplitude)
        case "/masterMeter":
            guard message.arguments.count >= 4 else { return }
            onMasterMeter?(Double(message.arguments[2].floatValue),
                           Double(message.arguments[3].floatValue))
        default:
            break
        }
    }

    // MARK: - Graph construction

    /// Builds the persistent part of the graph. Voices are created later, when
    /// a track actually has a sample.
    func buildGraph() {
        // Execution order is head-to-tail: voices, strips, effects, master.
        server.send([
            OSCMessage("/g_new", [.int(Group.voices), .int(0), .int(0)]),
            OSCMessage("/g_new", [.int(Group.strips), .int(3), .int(Group.voices)]),
            OSCMessage("/g_new", [.int(Group.effects), .int(3), .int(Group.strips)]),
            OSCMessage("/g_new", [.int(Group.performance), .int(3), .int(Group.effects)]),
            OSCMessage("/g_new", [.int(Group.master), .int(3), .int(Group.performance)])
        ])

        buildGrainEnvelopes()

        for index in 0..<Self.trackCount {
            server.send(OSCMessage("/s_new", [
                .string("granolaStrip"), .int(Node.strip(index)), .int(0), .int(Group.strips),
                .string("in"), .int(Bus.track(index)),
                .string("mixOut"), .int(Bus.mix),
                .string("perfOut"), .int(Bus.performance),
                .string("reverbOut"), .int(Bus.reverb),
                .string("delayOut"), .int(Bus.delay),
                .string("index"), .int(Int32(index))
            ]))
        }

        // The terminator must exist before any effect, since links are always
        // inserted immediately in front of it.
        server.send(OSCMessage("/s_new", [
            .string("granolaPerfOut"), .int(Node.performanceOut), .int(0), .int(Group.performance),
            .string("in"), .int(Bus.performance),
            .string("out"), .int(Bus.mix),
            .string("levelBus"), .int(Bus.chainLevel)
        ]))

        // Added at the head AFTER the tail, so it lands in front of it and
        // every effect inserted later sits between the two.
        server.send(OSCMessage("/s_new", [
            .string("granolaPerfIn"), .int(Node.performanceIn), .int(0), .int(Group.performance),
            .string("in"), .int(Bus.performance),
            .string("levelBus"), .int(Bus.chainLevel)
        ]))

        server.send(OSCMessage("/s_new", [
            .string("granolaReverb"), .int(Node.reverb), .int(0), .int(Group.effects),
            .string("in"), .int(Bus.reverb),
            .string("out"), .int(Bus.performance)
        ]))

        server.send(OSCMessage("/s_new", [
            .string("granolaDelay"), .int(Node.delay), .int(0), .int(Group.effects),
            .string("in"), .int(Bus.delay),
            .string("out"), .int(Bus.performance)
        ]))

        server.send(OSCMessage("/s_new", [
            .string("granolaMaster"), .int(Node.master), .int(0), .int(Group.master),
            .string("in"), .int(Bus.mix),
            .string("out"), .int(0),
            .string("recOut"), .int(Bus.record)
        ]))
    }

    // MARK: - Performance FX chain

    private var nextEffectNode: Int32 = 3000

    /// Appends a link to the end of the chain.
    ///
    /// Every link is created with addAction 2 (add-before) against the
    /// terminator, so it lands at the tail of the existing chain. Series order
    /// is therefore just node order, and nothing needs re-patching when links
    /// come and go.
    @discardableResult
    func addEffect(_ instance: FXInstance, fade: Double = 0.04, autoGain: Bool = true) -> Int32 {
        nextEffectNode += 1
        let node = nextEffectNode

        var args: [OSCValue] = [
            .string(instance.effect.synthDefName), .int(node),
            .int(2), .int(Node.performanceOut),          // 2 = add before target
            .string("bus"), .int(Bus.performance),
            .string("mix"), .float(Float(instance.mix)),
            .string("fade"), .float(Float(fade)),
            .string("autoGain"), .float(autoGain ? 1 : 0),
            .string("lfoTarget"), .float(Float(instance.lfoTarget)),
            .string("lfoRate"), .float(Float(instance.lfoRate)),
            .string("lfoDepth"), .float(Float(instance.lfoDepth)),
            .string("lfoShape"), .float(Float(instance.lfoShape))
        ]
        for (index, value) in instance.params.enumerated() {
            guard index < 10 else { break }
            let letter = String(UnicodeScalar(97 + index)!)   // a, b, c, …
            args.append(.string(letter))
            args.append(.float(Float(value)))
        }
        server.send(OSCMessage("/s_new", args))
        return node
    }

    /// Releases a link. The gate runs its fade, so removing a link mid-signal
    /// does not click, and the chain closes up behind it.
    func removeEffect(node: Int32, fade: Double = 0.04) {
        guard node != 0 else { return }
        // Set the release time before opening the gate: EnvGen reads it as the
        // segment starts, so a fade changed since the link was created still
        // applies to its fade-out.
        server.send(OSCMessage("/n_set", [
            .int(node), .string("fade"), .float(Float(fade)), .string("gate"), .float(0)
        ]))
    }

    func setEffectParam(node: Int32, index: Int, value: Double) {
        guard node != 0, index < 10 else { return }
        let letter = String(UnicodeScalar(97 + index)!)
        server.send(OSCMessage("/n_set", [.int(node), .string(letter), .float(Float(value))]))
    }

    func setEffectControl(node: Int32, key: String, value: Double) {
        guard node != 0 else { return }
        server.send(OSCMessage("/n_set", [.int(node), .string(key), .float(Float(value))]))
    }

    /// Routes a track either through the performance chain or straight to the
    /// mix. Switching the strip's output bus is all it takes.
    /// Chain-wide gain matching at the terminator.
    func setChainAutoGain(_ enabled: Bool) {
        server.send(OSCMessage("/n_set", [
            .int(Node.performanceOut), .string("autoGain"), .float(enabled ? 1 : 0)
        ]))
    }

    func setTrackRouting(track: Int, throughPerformance: Bool) {
        // A crossfade target, not a bus reassignment — see granolaStrip.
        server.send(OSCMessage("/n_set", [
            .int(Node.strip(track)), .string("routing"),
            .float(throughPerformance ? 1 : 0)
        ]))
    }

    // MARK: - Recording

    private(set) var isRecording = false

    /// Records the post-limiter master output straight to disk via DiskOut, so
    /// the file matches what was heard.
    func startRecording(to url: URL, completion: @escaping (Bool) -> Void) {
        guard !isRecording else { completion(false); return }

        server.send(OSCMessage("/b_alloc", [.int(Buffer.recorder), .int(65536), .int(2)]))
        sync { [weak self] allocated in
            guard let self else { return }
            guard allocated else { completion(false); return }

            // leaveOpen = 1 keeps the file streaming for DiskOut.
            self.server.send(OSCMessage("/b_write", [
                .int(Buffer.recorder), .string(url.path),
                .string("wav"), .string("float"),
                .int(0), .int(0), .int(1)
            ]))
            self.sync { opened in
                guard opened else { completion(false); return }
                self.server.send(OSCMessage("/s_new", [
                    .string("granolaRecorder"), .int(Node.recorder), .int(1), .int(Group.master),
                    .string("in"), .int(Bus.record),
                    .string("buf"), .int(Buffer.recorder)
                ]))
                self.isRecording = true
                completion(true)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        server.send(OSCMessage("/n_free", [.int(Node.recorder)]))
        // Give DiskOut a beat to flush before the file is closed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.server.send(OSCMessage("/b_close", [.int(Buffer.recorder)]))
            self.server.send(OSCMessage("/b_free", [.int(Buffer.recorder)]))
        }
    }

    func teardownGraph() {
        loadedTracks.removeAll()
        voiceNodes.removeAll()
        server.send(OSCMessage("/g_freeAll", [.int(0)]))
    }

    // MARK: - Grain envelopes

    /// Window shapes for the grain envelope. Index 0 is scsynth's built-in
    /// Hann window (`-1`); the rest are uploaded as buffers at boot.
    /// Raw values are deliberately NOT renumbered: saved projects store this
    /// as an integer, and the envelope buffers are addressed as
    /// `grainEnvelopeBase + rawValue`. Hann (0) and Triangle (5) were removed;
    /// anything holding those falls back to Gaussian.
    enum GrainShape: Int, CaseIterable, Identifiable {
        case gaussian = 1
        case percussive = 2
        case reversePercussive = 3
        case plateau = 4

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .gaussian: return "Gaussian"
            case .percussive: return "Percussive"
            case .reversePercussive: return "Reverse"
            case .plateau: return "Plateau"
            }
        }

        var bufferNumber: Int32 { Buffer.grainEnvelopeBase + Int32(rawValue) }

        func sample(at t: Double) -> Float {
            switch self {
            case .gaussian:
                let x = (t - 0.5) / 0.22
                return Float(exp(-0.5 * x * x))
            case .percussive:
                return Float(pow(1 - t, 3) * (1 - exp(-t * 60)))
            case .reversePercussive:
                let r = 1 - t
                return Float(pow(1 - r, 3) * (1 - exp(-r * 60)))
            case .plateau:
                // Tukey window: flat top with short raised-cosine edges.
                let edge = 0.15
                if t < edge { return Float(0.5 - 0.5 * cos(.pi * t / edge)) }
                if t > 1 - edge { return Float(0.5 - 0.5 * cos(.pi * (1 - t) / edge)) }
                return 1
            }
        }
    }

    private static let grainEnvelopeSize = 1024

    /// Uploads the grain window shapes.
    ///
    /// The allocation and the fill CANNOT be sent back to back. `/b_alloc` is
    /// asynchronous — scsynth defers it to its command thread — while
    /// `/b_setn` executes immediately on the audio thread. Sent together, the
    /// data arrives before the buffer exists and is discarded, leaving a
    /// buffer of zeros. A grain windowed by zeros is silence, which is exactly
    /// how every shape except Hann behaved (Hann is -1, GrainBuf's built-in
    /// window, so it never touched a buffer at all).
    private func buildGrainEnvelopes() {
        let size = Self.grainEnvelopeSize
        let shapes = GrainShape.allCases

        for shape in shapes {
            server.send(OSCMessage("/b_alloc", [.int(shape.bufferNumber), .int(Int32(size)), .int(1)]))
        }

        sync { [weak self] allocated in
            guard let self, allocated else { return }
            for shape in shapes {
                var samples = [Float](repeating: 0, count: size)
                for i in 0..<size {
                    samples[i] = shape.sample(at: Double(i) / Double(size - 1))
                }
                // /b_setn in chunks — a single datagram cannot carry 1024 floats.
                let chunk = 256
                var offset = 0
                while offset < size {
                    let count = min(chunk, size - offset)
                    var args: [OSCValue] = [.int(shape.bufferNumber),
                                            .int(Int32(offset)), .int(Int32(count))]
                    for i in offset..<(offset + count) { args.append(.float(samples[i])) }
                    self.server.send(OSCMessage("/b_setn", args))
                    offset += count
                }
            }
        }
    }

    // MARK: - Samples

    /// Loads a sample into the track's buffer pair. Stereo files fill both
    /// buffers; mono files point the right channel at the same buffer.
    func loadSample(track: Int, sample: SampleLoader.Loaded, completion: @escaping (Bool) -> Void) {
        let left = Buffer.left(track)
        let right = Buffer.right(track)
        let path = sample.serverURL.path

        freeVoice(track: track)
        server.send([
            OSCMessage("/b_free", [.int(left)]),
            OSCMessage("/b_free", [.int(right)])
        ])

        // /b_allocReadChannel is asynchronous; /sync gives us a completion edge
        // so a voice is never started against a half-filled buffer.
        server.send(OSCMessage("/b_allocReadChannel", [
            .int(left), .string(path), .int(0), .int(0), .int(0)
        ]))
        if sample.channels >= 2 {
            server.send(OSCMessage("/b_allocReadChannel", [
                .int(right), .string(path), .int(0), .int(0), .int(1)
            ]))
        }

        sync { ok in
            if ok { self.loadedTracks.insert(track) }
            completion(ok)
        }
    }

    func rightBuffer(for track: Int, channels: Int) -> Int32 {
        channels >= 2 ? Buffer.right(track) : Buffer.left(track)
    }

    // MARK: - Voices

    func startVoice(track: Int, channels: Int, parameters: [ParamID: Double], grainShape: GrainShape) {
        guard loadedTracks.contains(track) else { return }
        freeVoice(track: track)

        nextVoiceNode += 1
        if nextVoiceNode > 1099 { nextVoiceNode = 1000 }   // stay clear of strips at 1100
        let node = nextVoiceNode
        voiceNodes[track] = node

        var args: [OSCValue] = [
            .string("granolaVoice"), .int(node), .int(0), .int(Group.voices),
            .string("out"), .int(Bus.track(track)),
            .string("bufL"), .int(Buffer.left(track)),
            .string("bufR"), .int(rightBuffer(for: track, channels: channels)),
            .string("envBuf"), .int(shapeBuffer(grainShape))
        ]
        for (param, value) in parameters where param.target == .voice {
            args.append(.string(param.oscKey))
            args.append(.float(Float(value)))
        }
        server.send(OSCMessage("/s_new", args))
    }

    private func shapeBuffer(_ shape: GrainShape) -> Int32 { shape.bufferNumber }

    func freeVoice(track: Int) {
        guard let node = voiceNodes[track] else { return }
        // gate 0 lets the release envelope run instead of clicking.
        server.send(OSCMessage("/n_set", [.int(node), .string("gate"), .float(0)]))
        voiceNodes[track] = nil
    }

    func setGrainShape(track: Int, shape: GrainShape) {
        guard let node = voiceNodes[track] else { return }
        server.send(OSCMessage("/n_set", [
            .int(node), .string("envBuf"), .int(shapeBuffer(shape))
        ]))
    }

    // MARK: - Parameters

    func set(track: Int, param: ParamID, value: Double) {
        let node = param.target == .voice ? voiceNode(track) : Node.strip(track)
        guard node != 0 else { return }
        server.send(OSCMessage("/n_set", [
            .int(node), .string(param.oscKey), .float(Float(value))
        ]))
    }

    /// Coalesces several parameter changes into one message — used by the macro
    /// encoder, where up to four values move on every tick.
    func set(track: Int, values: [(ParamID, Double)]) {
        var voiceArgs: [OSCValue] = [.int(voiceNode(track))]
        var stripArgs: [OSCValue] = [.int(Node.strip(track))]
        for (param, value) in values {
            if param.target == .voice {
                voiceArgs.append(.string(param.oscKey))
                voiceArgs.append(.float(Float(value)))
            } else {
                stripArgs.append(.string(param.oscKey))
                stripArgs.append(.float(Float(value)))
            }
        }
        if voiceArgs.count > 1 && voiceNode(track) != 0 { server.send(OSCMessage("/n_set", voiceArgs)) }
        if stripArgs.count > 1 { server.send(OSCMessage("/n_set", stripArgs)) }
    }

    func setMuted(track: Int, muted: Bool) {
        server.send(OSCMessage("/n_set", [
            .int(Node.strip(track)), .string("mute"), .float(muted ? 1 : 0)
        ]))
    }

    // MARK: - Master and effects

    func setMasterLevel(_ level: Double) {
        server.send(OSCMessage("/n_set", [.int(Node.master), .string("amp"), .float(Float(level))]))
    }

    /// Master effect parameters are addressed by SynthDef control name, so the
    /// model can push whatever set it holds without the engine knowing them
    /// individually.
    func setReverb(_ values: [(String, Double)]) {
        setNode(Node.reverb, values)
    }

    func setDelay(_ values: [(String, Double)]) {
        setNode(Node.delay, values)
    }

    private func setNode(_ node: Int32, _ values: [(String, Double)]) {
        guard !values.isEmpty else { return }
        var args: [OSCValue] = [.int(node)]
        for (key, value) in values {
            args.append(.string(key))
            args.append(.float(Float(value)))
        }
        server.send(OSCMessage("/n_set", args))
    }

    func panic() {
        server.send(OSCMessage("/g_freeAll", [.int(Group.voices)]))
        loadedTracks.removeAll()
        voiceNodes.removeAll()
    }

    // MARK: - Sync

    private var syncID: Int32 = 0
    private let syncLock = NSLock()

    /// Round-trips a `/sync` so callers can wait for asynchronous server
    /// commands (buffer reads, def loads) to actually finish.
    func sync(timeout: TimeInterval = 20, completion: @escaping (Bool) -> Void) {
        syncLock.lock()
        syncID += 1
        let id = syncID
        syncLock.unlock()

        let guardLock = NSLock()
        var finished = false
        var token: UUID?

        func finish(_ ok: Bool) {
            guardLock.lock()
            defer { guardLock.unlock() }
            guard !finished else { return }
            finished = true
            if let token { server.removeListener(token) }
            completion(ok)
        }

        token = server.addListener { message in
            if message.address == "/synced", message.arguments.first?.intValue == Int(id) {
                finish(true)
            }
        }

        server.send(OSCMessage("/sync", [.int(id)]))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
