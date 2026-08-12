import Foundation
import CoreMIDI
import Combine

/// CoreMIDI driver for the M-Vave SMC-Mixer in DAW (Mackie Control) mode.
///
/// Behaviour here follows the hardware spec: the device is momentary and
/// stateless in DAW mode — the host owns every LED — and the BLE link drops
/// whenever the device changes mode, so endpoint loss is routine rather than
/// fatal.
final class SMCMixer: ObservableObject {

    // MARK: - Hardware map

    enum Button: Hashable {
        case rec(Int)      // notes 0–7
        case solo(Int)     // notes 8–15
        case mute(Int)     // notes 16–23
        case select(Int)   // notes 24–31
        case bankLeft, bankRight
        case play, stop, record, rewind, fastForward
        case cursorUp, cursorDown, cursorLeft, cursorRight

        /// The note that both reports a press and addresses that button's LED.
        var note: UInt8 {
            switch self {
            case .rec(let n): return UInt8(n)
            case .solo(let n): return UInt8(8 + n)
            case .mute(let n): return UInt8(16 + n)
            case .select(let n): return UInt8(24 + n)
            case .bankLeft: return 46
            case .bankRight: return 47
            case .rewind: return 91
            case .fastForward: return 92
            case .stop: return 93
            case .play: return 94
            case .record: return 95
            case .cursorUp: return 96
            case .cursorDown: return 97
            case .cursorLeft: return 98
            case .cursorRight: return 99
            }
        }

        static func from(note: UInt8) -> Button? {
            switch note {
            case 0...7: return .rec(Int(note))
            case 8...15: return .solo(Int(note) - 8)
            case 16...23: return .mute(Int(note) - 16)
            case 24...31: return .select(Int(note) - 24)
            case 46: return .bankLeft
            case 47: return .bankRight
            case 91: return .rewind
            case 92: return .fastForward
            case 93: return .stop
            case 94: return .play
            case 95: return .record
            case 96: return .cursorUp
            case 97: return .cursorDown
            case 98: return .cursorLeft
            case 99: return .cursorRight
            default: return nil
            }
        }
    }

    enum Mode: String {
        case unknown = "waiting…"
        case controlChange = "User/CC mode"
        case daw = "DAW mode"
    }

    // MARK: - Published state

    @Published private(set) var isConnected = false
    @Published private(set) var mode: Mode = .unknown
    @Published private(set) var statusText = "Looking for SMC-Mixer…"

    /// True once we have seen traffic that proves the device is in CC mode —
    /// the app can then tell the user to switch, instead of silently not
    /// lighting any LEDs.
    var needsDAWModeSwitch: Bool { isConnected && mode == .controlChange }

    // MARK: - Callbacks (delivered on the main queue)

    var onFader: ((Int, Double) -> Void)?
    var onEncoder: ((Int, Int) -> Void)?
    var onButton: ((Button, Bool) -> Void)?

    // MARK: - CoreMIDI

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    // MARK: - Diagnostics
    //
    // Every inbound button event and every outbound LED write, timestamped, in
    // /tmp/granola-midi.log. Cheap, and the only way to tell a logic bug from
    // the device doing something of its own accord.

    private static let logURL = URL(fileURLWithPath: "/tmp/granola-midi.log")
    private static let logStart = Date()
    private static let logQueue = DispatchQueue(label: "granola.smc.log")

    static func log(_ message: String) {
        logQueue.async {
            let line = String(format: "[%8.3f] %@\n", Date().timeIntervalSince(logStart), message)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private let ledQueue = DispatchQueue(label: "granola.smc.led")
    /// Last value actually transmitted, used to diff writes.
    private var ledState: [UInt8: Bool] = [:]
    /// What the app wants each LED to be, regardless of what was last sent.
    /// Needed because the device overrides LEDs behind our back (see
    /// `reassertLED`), which makes `ledState` an unreliable picture of the
    /// surface.
    private var desiredLED: [UInt8: Bool] = [:]
    private var pendingLED: [UInt8: Bool] = [:]
    private var flushScheduled = false

    // MARK: - Lifecycle

    func start() {
        // Idempotent: a re-entry after an engine restart should just re-scan
        // rather than create a second CoreMIDI client.
        guard client == 0 else { rescan(); return }

        // One log per run, so it stays readable.
        try? FileManager.default.removeItem(at: Self.logURL)

        var notifyBlock: MIDINotifyBlock = { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                // Mode changes and BLE dropouts both surface as setup changes.
                DispatchQueue.main.async { self?.rescan() }
            default:
                break
            }
        }

        let status = MIDIClientCreateWithBlock("Granola" as CFString, &client, notifyBlock)
        guard status == noErr else {
            statusText = "CoreMIDI unavailable (error \(status))"
            return
        }
        _ = notifyBlock

        MIDIInputPortCreateWithBlock(client, "Granola In" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.handle(packetList)
        }
        MIDIOutputPortCreate(client, "Granola Out" as CFString, &outputPort)

        rescan()
    }

    func stop() {
        disconnectSource()
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        isConnected = false
    }

    // MARK: - Discovery

    /// Matches on `SMC-Mixer` in the device/display name. The endpoint's own
    /// `name` is just "Bluetooth" and would collide with any other BLE MIDI
    /// peripheral.
    private func matchesMixer(_ endpoint: MIDIEndpointRef) -> Bool {
        for property in [kMIDIPropertyDisplayName, kMIDIPropertyName, kMIDIPropertyModel] {
            if let value = stringProperty(endpoint, property),
               value.localizedCaseInsensitiveContains("SMC-Mixer") {
                return true
            }
        }
        var device = MIDIEntityRef()
        if MIDIEndpointGetEntity(endpoint, &device) == noErr {
            var owner = MIDIDeviceRef()
            if MIDIEntityGetDevice(device, &owner) == noErr,
               let name = stringProperty(owner, kMIDIPropertyName),
               name.localizedCaseInsensitiveContains("SMC-Mixer") {
                return true
            }
        }
        return false
    }

    private func stringProperty(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func rescan() {
        let previous = source
        disconnectSource()

        var foundSource = MIDIEndpointRef()
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            if matchesMixer(endpoint) { foundSource = endpoint; break }
        }

        var foundDestination = MIDIEndpointRef()
        for index in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            if matchesMixer(endpoint) { foundDestination = endpoint; break }
        }

        guard foundSource != 0 else {
            isConnected = false
            mode = .unknown
            statusText = "SMC-Mixer not found — pair it in Audio MIDI Setup"
            return
        }

        source = foundSource
        destination = foundDestination
        MIDIPortConnectSource(inputPort, source, nil)
        isConnected = true

        if destination == 0 {
            // Feedback is impossible with the input endpoint alone.
            statusText = "SMC-Mixer connected (no output endpoint — LEDs unavailable)"
        } else {
            statusText = "SMC-Mixer connected"
        }

        if previous != foundSource {
            mode = .unknown
        }
        // The device retains nothing across a reconnect, so push everything.
        resendAllLEDs()
    }

    private func disconnectSource() {
        if source != 0 && inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, source)
        }
        source = 0
        destination = 0
    }

    // MARK: - Input

    private func handle(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            withUnsafeBytes(of: packet.data) { raw in
                let length = Int(packet.length)
                var index = 0
                while index < length {
                    let status = raw[index]
                    guard status >= 0x80 else { index += 1; continue }
                    let kind = status & 0xF0
                    let channel = Int(status & 0x0F)

                    switch kind {
                    case 0x90 where index + 2 < length:
                        decodeNote(raw[index + 1], velocity: raw[index + 2])
                        index += 3
                    case 0x80 where index + 2 < length:
                        decodeNote(raw[index + 1], velocity: 0)
                        index += 3
                    case 0xB0 where index + 2 < length:
                        decodeControlChange(raw[index + 1], value: raw[index + 2])
                        index += 3
                    case 0xE0 where index + 2 < length:
                        decodePitchBend(channel: channel, lsb: raw[index + 1], msb: raw[index + 2])
                        index += 3
                    default:
                        index += 1
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func noteMode(_ newMode: Mode) {
        if mode != newMode {
            DispatchQueue.main.async { [weak self] in self?.mode = newMode }
        }
    }

    private func decodeNote(_ note: UInt8, velocity: UInt8) {
        // Note traffic only exists in DAW mode.
        noteMode(.daw)
        guard let button = Button.from(note: note) else { return }
        let pressed = velocity >= 0x40
        Self.log("IN   note \(note) vel \(velocity) -> \(pressed ? "PRESS" : "release")")
        DispatchQueue.main.async { [weak self] in self?.onButton?(button, pressed) }

        // The device blanks this button's LED on release; put it back.
        if !pressed { reassertLED(note: note) }
    }

    private func decodeControlChange(_ controller: UInt8, value: UInt8) {
        guard (16...23).contains(controller) else {
            // Any other CC means the device is speaking User/CC mode.
            noteMode(.controlChange)
            return
        }
        let index = Int(controller) - 16
        // Relative encoding: 0x01–0x3F clockwise, 0x41–0x7F counter-clockwise.
        let delta: Int = value <= 0x3F ? Int(value) : -(Int(value) - 0x40)
        guard delta != 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.onEncoder?(index, delta) }
    }

    private func decodePitchBend(channel: Int, lsb: UInt8, msb: UInt8) {
        noteMode(.daw)
        guard channel < 8 else { return }
        let raw = Int(lsb) | (Int(msb) << 7)
        let value = Double(raw) / 16383.0
        DispatchQueue.main.async { [weak self] in self?.onFader?(channel, value) }
    }

    // MARK: - Output: button LEDs

    /// Requests an LED state. Writes are diffed and batched — BLE MIDI is far
    /// narrower than USB, and flooding it drops the link.
    func setLED(_ button: Button, on: Bool) {
        setLED(note: button.note, on: on)
    }

    func setLED(note: UInt8, on: Bool) {
        ledQueue.async { [weak self] in
            guard let self else { return }
            self.desiredLED[note] = on
            // Compare against what is actually queued, not only what was last
            // sent: a request that lands between a write and its flush would
            // otherwise be dropped, leaving the surface showing the old state.
            let effective = self.pendingLED[note] ?? self.ledState[note]
            if effective == on { return }
            self.pendingLED[note] = on
            Self.log("LED  note \(note) -> \(on ? "ON" : "off")")
            self.scheduleFlush()
        }
    }

    /// The device clears a button's own LED when that button is released, even
    /// in DAW mode where the host is supposed to own LED state. Confirmed on
    /// hardware: pressing a latching control logs `LED note 46 -> ON` with no
    /// matching off, yet the light goes out on release.
    ///
    /// So after every release we re-assert what the app actually wants. The
    /// write has to bypass the diff, because our cache still believes the LED
    /// is lit and would suppress the resend.
    private func reassertLED(note: UInt8) {
        ledQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.desiredLED[note] == true else { return }
            self.ledState[note] = nil
            self.pendingLED[note] = true
            Self.log("LED  note \(note) -> ON (re-assert after release)")
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        ledQueue.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            self?.flushLEDs()
        }
    }

    private func flushLEDs() {
        flushScheduled = false
        guard destination != 0, !pendingLED.isEmpty else { return }

        // ~40 messages per burst with a short pause proved reliable over BLE.
        let batch = Array(pendingLED.prefix(40))
        for (note, on) in batch {
            ledState[note] = on
            pendingLED.removeValue(forKey: note)
            send([0x90, note, on ? 0x7F : 0x00])
        }

        if !pendingLED.isEmpty {
            flushScheduled = true
            ledQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.flushLEDs() }
        }
    }

    /// Forces the next flush to re-transmit everything — used after a
    /// reconnect, since the device does not retain LED state.
    func resendAllLEDs() {
        ledQueue.async { [weak self] in
            guard let self else { return }
            // Re-send what the app wants, not what was last transmitted — the
            // device may have changed things underneath us.
            for (note, on) in self.desiredLED { self.pendingLED[note] = on }
            self.ledState.removeAll()
            if !self.pendingLED.isEmpty { self.scheduleFlush() }
        }
    }

    // MARK: - Output: fader null indicators

    /// Sets the host's notion of track volume for a strip. The device compares
    /// this against the physical fader and flashes that strip's indicator on
    /// mismatch — this is the only way to drive those LEDs.
    func setTrackVolume(_ index: Int, value: Double) {
        guard destination != 0, (0..<8).contains(index) else { return }
        let raw = Int((value.clamped(0, 1) * 16383).rounded())
        let lsb = UInt8(raw & 0x7F)
        let msb = UInt8((raw >> 7) & 0x7F)
        send([0xE0 | UInt8(index), lsb, msb])
    }

    // MARK: - Raw send

    private func send(_ bytes: [UInt8]) {
        guard destination != 0, outputPort != 0 else { return }
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        guard packet != nil else { return }
        MIDISend(outputPort, destination, &packetList)
    }
}
