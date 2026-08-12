import Foundation
import CoreMIDI
import Combine

/// CoreMIDI driver for the M-Vave SMC-PAD Pocket, used as the performance FX
/// surface.
///
/// The pads are configured as **CC toggles on channel 4, CC 1–16**, which means
/// the device owns its own latched state and lights its own LED. Granola does
/// not — and cannot — drive those LEDs, so the app is strictly subordinate: it
/// takes whatever the pad reports and matches it. That is the opposite of the
/// mixer's DAW-mode relationship, and it is why the two surfaces have separate
/// drivers rather than one generalised one.
final class PadController: ObservableObject {

    static let padCount = 16
    /// Channel 4, one-based, as configured in Midi Suite.
    static let channel: UInt8 = 3      // zero-based on the wire

    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "SMC-PAD not found"

    /// Latched state as last reported by the hardware. The device is the source
    /// of truth; this only mirrors it.
    @Published private(set) var padState = [Bool](repeating: false, count: PadController.padCount)

    /// Fires with (pad index 0-15, on/off).
    var onPad: ((Int, Bool) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var source = MIDIEndpointRef()

    // MARK: - Grid geometry
    //
    // CC 1–4 are the BOTTOM row, rising to CC 13–16 on the top row. The UI grid
    // is drawn top-down, so row 0 on screen is CC 13–16.

    static func pad(forRow row: Int, column: Int) -> Int {
        // row 0 = top = CCs 13-16 → indices 12-15
        let rowFromBottom = 3 - row
        return rowFromBottom * 4 + column
    }

    /// Bottom row (CC 1–4) holds the FX chain slots.
    static func fxSlot(forPad pad: Int) -> Int? { pad < 4 ? pad : nil }

    /// Second row from the bottom (CC 5–8) selects the grain envelope, left to
    /// right: Gaussian, Percussive, Plateau, Reverse.
    static let shapeRow: [GranolaEngine.GrainShape] =
        [.gaussian, .percussive, .plateau, .reversePercussive]

    static func grainShape(forPad pad: Int) -> GranolaEngine.GrainShape? {
        guard (4...7).contains(pad) else { return nil }
        return shapeRow[pad - 4]
    }

    /// Top two rows (CC 9–16) select which tracks the chain processes.
    static func trackIndex(forPad pad: Int) -> Int? { pad >= 8 ? pad - 8 : nil }

    // MARK: - Lifecycle

    func start() {
        guard client == 0 else { rescan(); return }

        var notify: MIDINotifyBlock = { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                DispatchQueue.main.async { self?.rescan() }
            default: break
            }
        }
        guard MIDIClientCreateWithBlock("GranolaPads" as CFString, &client, notify) == noErr else {
            statusText = "CoreMIDI unavailable"
            return
        }
        _ = notify

        MIDIInputPortCreateWithBlock(client, "Granola Pads In" as CFString, &inputPort) { [weak self] list, _ in
            self?.handle(list)
        }
        rescan()
    }

    func stop() {
        if source != 0 && inputPort != 0 { MIDIPortDisconnectSource(inputPort, source) }
        source = 0
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        isConnected = false
    }

    private func property(_ object: MIDIObjectRef, _ key: CFString) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr else { return "" }
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    private func matches(_ endpoint: MIDIEndpointRef) -> Bool {
        for key in [kMIDIPropertyDisplayName, kMIDIPropertyName, kMIDIPropertyModel] {
            if property(endpoint, key).localizedCaseInsensitiveContains("SMC-PAD") { return true }
        }
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(endpoint, &entity) == noErr {
            var device = MIDIDeviceRef()
            if MIDIEntityGetDevice(entity, &device) == noErr,
               property(device, kMIDIPropertyName).localizedCaseInsensitiveContains("SMC-PAD") {
                return true
            }
        }
        return false
    }

    private func rescan() {
        if source != 0 && inputPort != 0 { MIDIPortDisconnectSource(inputPort, source) }
        source = 0

        // The pad presents several ports over USB; any of them carries the
        // toggles, so take the first that matches and is not the private port
        // if a public one exists.
        var candidates: [MIDIEndpointRef] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            if matches(endpoint) { candidates.append(endpoint) }
        }
        guard let chosen = candidates.first else {
            isConnected = false
            statusText = "SMC-PAD not found"
            return
        }
        source = chosen
        MIDIPortConnectSource(inputPort, source, nil)
        isConnected = true
        statusText = "SMC-PAD connected"
    }

    // MARK: - Input

    private func handle(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            withUnsafeBytes(of: packet.data) { raw in
                let length = Int(packet.length)
                var index = 0
                while index + 2 < length {
                    let status = raw[index]
                    if (status & 0xF0) == 0xB0 {
                        let channel = status & 0x0F
                        let cc = raw[index + 1]
                        let value = raw[index + 2]
                        if channel == Self.channel, (1...16).contains(cc) {
                            report(pad: Int(cc) - 1, on: value >= 64)
                        }
                        index += 3
                    } else if status >= 0x80 {
                        index += 3
                    } else {
                        index += 1
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func report(pad: Int, on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.padState.indices.contains(pad) else { return }
            // Follow the hardware even if it disagrees with us: it is the one
            // holding the latch and lighting the LED.
            self.padState[pad] = on
            self.onPad?(pad, on)
        }
    }
}
