import Foundation
import Darwin
import CoreAudio

/// Owns the embedded scsynth process and the UDP/OSC link to it.
///
/// scsynth and its plugins ship inside Granola.app, so there is no external
/// SuperCollider dependency at runtime. sclang is never involved — SynthDefs
/// are precompiled at build time and loaded with `/d_loadDir`.
final class SCServer {

    enum State: Equatable {
        case stopped
        case booting
        case running
        case failed(String)
    }

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    /// Inbound OSC is fanned out to every registered listener. A registry
    /// rather than a single closure is what makes overlapping `/sync` waits
    /// safe — each waiter adds and removes only its own entry.
    private var listeners: [UUID: (OSCMessage) -> Void] = [:]
    private let listenerLock = NSLock()

    @discardableResult
    func addListener(_ handler: @escaping (OSCMessage) -> Void) -> UUID {
        let token = UUID()
        listenerLock.lock()
        listeners[token] = handler
        listenerLock.unlock()
        return token
    }

    func removeListener(_ token: UUID) {
        listenerLock.lock()
        listeners.removeValue(forKey: token)
        listenerLock.unlock()
    }

    private func dispatch(_ message: OSCMessage) {
        listenerLock.lock()
        let handlers = Array(listeners.values)
        listenerLock.unlock()
        for handler in handlers { handler(message) }
    }

    private var process: Process?
    private var socket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var serverAddress = sockaddr_in()
    private let port: UInt16
    private let queue = DispatchQueue(label: "granola.scserver")
    private let sendLock = NSLock()

    /// Node/bus/buffer allocation is done here rather than on the server, which
    /// has no allocator of its own — the client is authoritative by design.
    private var nextNodeID: Int32 = 2000

    init(port: UInt16 = 57130) {
        self.port = port
    }

    deinit { shutdown() }

    // MARK: - Resource discovery

    /// scsynth, its plugins and the compiled synthdefs, resolved from the app
    /// bundle first and the development tree second so `swift run` also works.
    struct Resources {
        let scsynth: URL
        let plugins: URL
        let synthdefs: URL
    }

    static func locateResources() -> Resources? {
        var roots: [URL] = []
        if let bundled = Bundle.main.resourceURL {
            roots.append(bundled)
        }
        // Development fallback: walk up from the executable to the package root.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            roots.append(dir.appendingPathComponent("Resources"))
            dir = dir.deletingLastPathComponent()
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources"))

        let fm = FileManager.default
        for root in roots {
            let scsynth = root.appendingPathComponent("SuperCollider/scsynth")
            let plugins = root.appendingPathComponent("SuperCollider/plugins")
            let defs = root.appendingPathComponent("synthdefs")
            if fm.isExecutableFile(atPath: scsynth.path), fm.fileExists(atPath: plugins.path) {
                return Resources(scsynth: scsynth, plugins: plugins, synthdefs: defs)
            }
        }

        // Last resort: a system SuperCollider install. Keeps `swift run` usable
        // before Scripts/build.sh has staged the embedded copy.
        let system = URL(fileURLWithPath: "/Applications/SuperCollider.app/Contents/Resources")
        if fm.isExecutableFile(atPath: system.appendingPathComponent("scsynth").path) {
            let defs = roots.first { fm.fileExists(atPath: $0.appendingPathComponent("synthdefs").path) }
            return Resources(
                scsynth: system.appendingPathComponent("scsynth"),
                plugins: system.appendingPathComponent("plugins"),
                synthdefs: (defs ?? system).appendingPathComponent("synthdefs")
            )
        }
        return nil
    }

    // MARK: - Audio device

    /// Name of the system's current default output device, as CoreAudio
    /// reports it — the same string scsynth matches against for `-H`.
    static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0
        else { return nil }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil,
                                         &nameSize, &name) == noErr
        else { return nil }

        let result = name as String
        return result.isEmpty ? nil : result
    }

    // MARK: - Lifecycle

    func boot(completion: @escaping (Bool) -> Void) {
        guard state == .stopped || isFailed else { completion(state == .running); return }
        guard let resources = Self.locateResources() else {
            state = .failed("Could not find the embedded SuperCollider server.")
            completion(false)
            return
        }

        state = .booting

        guard openSocket() else {
            state = .failed("Could not open a UDP socket to the audio server.")
            completion(false)
            return
        }

        let task = Process()
        task.executableURL = resources.scsynth
        var arguments = [
            "-u", String(port),          // UDP port
            "-a", "1024",                // audio bus channels
            // No input channels: Granola granulates files, so opening the mic
            // would trigger a permission prompt for a device it never reads.
            "-i", "0", "-o", "2",
            "-b", "2048",                // sample buffers
            "-n", "1024",                // control buses
            "-z", "64",                  // block size
            "-m", "262144",              // real-time memory (KB)
            "-w", "512",                 // wire buffers
            "-R", "0",                   // do not publish to Rendezvous
            "-l", "1",                   // one client
            "-U", resources.plugins.path
        ]

        // Pin the server to the default OUTPUT device. Without this, scsynth
        // opens the default input device too — which makes macOS raise a
        // microphone permission prompt for an app that only granulates files.
        // An output device reports zero input streams, so nothing is opened.
        if let output = Self.defaultOutputDeviceName() {
            arguments.append(contentsOf: ["-H", output])
            onLog?("granola: using audio device “\(output)”")
        }
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                self?.onLog?(String(line))
            }
        }

        task.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if self.state == .running || self.state == .booting {
                self.state = .failed("The audio server stopped unexpectedly (code \(proc.terminationStatus)).")
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed("Could not start the audio server: \(error.localizedDescription)")
            completion(false)
            return
        }
        process = task

        // Poll /status until the server answers. Enumerating CoreAudio devices
        // can take the better part of ten seconds on a machine with virtual
        // devices installed, so this window is generous on purpose.
        waitForServer(attempts: 450) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.state = .failed("The audio server did not respond. Check Sound settings and try again.")
                completion(false)
                return
            }
            self.send(OSCMessage("/notify", [.int(1)]))
            if FileManager.default.fileExists(atPath: resources.synthdefs.path) {
                self.send(OSCMessage("/d_loadDir", [.string(resources.synthdefs.path)]))
            }
            // /d_loadDir is asynchronous; give it a moment before the caller
            // starts creating synths from those defs.
            self.queue.asyncAfter(deadline: .now() + 0.35) {
                self.state = .running
                completion(true)
            }
        }
    }

    func shutdown() {
        if socket >= 0 { send(OSCMessage("/quit")) }
        readSource?.cancel()
        readSource = nil
        if socket >= 0 { close(socket); socket = -1 }
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        state = .stopped
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func waitForServer(attempts: Int, completion: @escaping (Bool) -> Void) {
        let answered = NSLock()
        var done = false
        var token: UUID?

        func finish(_ ok: Bool) {
            answered.lock()
            defer { answered.unlock() }
            guard !done else { return }
            done = true
            if let token { removeListener(token) }
            completion(ok)
        }

        token = addListener { message in
            if message.address == "/status.reply" { finish(true) }
        }

        func poll(_ remaining: Int) {
            answered.lock(); let finished = done; answered.unlock()
            guard !finished else { return }
            guard remaining > 0 else { finish(false); return }
            send(OSCMessage("/status"))
            queue.asyncAfter(deadline: .now() + 0.1) { poll(remaining - 1) }
        }
        poll(attempts)
    }

    // MARK: - Socket

    private func openSocket() -> Bool {
        socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return false }

        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        serverAddress.sin_family = sa_family_t(AF_INET)
        serverAddress.sin_port = port.bigEndian
        serverAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        serverAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = inet_addr("127.0.0.1")
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(socket); socket = -1; return false }

        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source
        return true
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(socket, &buffer, buffer.count, 0)
        guard count > 0 else { return }
        let data = Data(buffer[0..<count])
        for message in OSCMessage.decode(data) {
            if message.address == "/fail" {
                onLog?("server: /fail " + message.arguments.map(\.stringValue).joined(separator: " "))
            }
            dispatch(message)
        }
    }

    // MARK: - Sending

    func send(_ message: OSCMessage) {
        guard socket >= 0 else { return }
        let data = message.encoded()
        sendLock.lock()
        defer { sendLock.unlock() }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &serverAddress) { addr in
                addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(socket, bytes.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func send(_ messages: [OSCMessage]) {
        for message in messages { send(message) }
    }

    func allocNodeID() -> Int32 {
        nextNodeID += 1
        return nextNodeID
    }
}
