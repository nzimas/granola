import Foundation
import CoreMIDI

// Standalone MIDI monitor for the SMC-Mixer.
//
// Built to answer one question the hardware spec leaves open: does the Shift
// key transmit anything at all? The spec says it was "not observed
// transmitting any MIDI", which is not the same as proving it cannot — and the
// project save/load design depends on the answer.
//
// Build:  swiftc -O Scripts/midimon/main.swift -o build/midimon
// Run:    ./build/midimon

let start = Date()
var messageCount = 0

func stamp() -> String {
    String(format: "%7.3f", Date().timeIntervalSince(start))
}

func describe(_ bytes: [UInt8]) -> String {
    guard let status = bytes.first else { return "" }
    let kind = status & 0xF0
    let channel = Int(status & 0x0F) + 1

    switch kind {
    case 0x90 where bytes.count >= 3:
        let note = bytes[1]
        let velocity = bytes[2]
        let action = velocity >= 0x40 ? "PRESS  " : "release"
        return "NoteOn  ch\(channel) note \(String(format: "%3d", note)) vel \(String(format: "%3d", velocity))  \(action)  \(buttonName(note))"
    case 0x80 where bytes.count >= 3:
        return "NoteOff ch\(channel) note \(bytes[1])  \(buttonName(bytes[1]))"
    case 0xB0 where bytes.count >= 3:
        let cc = bytes[1], value = bytes[2]
        if (16...23).contains(cc) {
            let delta = value <= 0x3F ? Int(value) : -(Int(value) - 0x40)
            return "CC      ch\(channel) cc \(cc) val \(value)   encoder \(Int(cc) - 15) delta \(delta > 0 ? "+" : "")\(delta)"
        }
        return "CC      ch\(channel) cc \(cc) val \(value)   <-- NOT an encoder CC"
    case 0xE0 where bytes.count >= 3:
        let raw = Int(bytes[1]) | (Int(bytes[2]) << 7)
        return "PitchBd ch\(channel) value \(raw)   fader \(channel)"
    default:
        return "other   " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

func buttonName(_ note: UInt8) -> String {
    switch note {
    case 0...7: return "Rec/Arm \(note + 1)"
    case 8...15: return "Solo \(note - 7)"
    case 16...23: return "Mute \(note - 15)"
    case 24...31: return "Select \(note - 23)"
    case 46: return "Bank Left"
    case 47: return "Bank Right"
    case 91: return "Rewind"
    case 92: return "Fast Forward"
    case 93: return "Stop"
    case 94: return "Play"
    case 95: return "Record"
    case 96: return "Cursor Up"
    case 97: return "Cursor Down"
    case 98: return "Cursor Left"
    case 99: return "Cursor Right"
    default: return "UNMAPPED note \(note) <-- interesting!"
    }
}

func stringProperty(_ object: MIDIObjectRef, _ key: CFString) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, key, &value) == noErr else { return "" }
    return (value?.takeRetainedValue() as String?) ?? ""
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("GranolaMonitor" as CFString, &client, nil)

// --leds walks the eight project-slot buttons one at a time.
//
// The hardware spec verifies LEDs across notes 0-95 but leaves 96-99 (the four
// cursor buttons) unverified — and those are project slots 5-8. This says
// plainly whether they can light at all.
// --latch <note> answers two questions in sequence: can the host light this LED
// at all, and if so does the device clear it on a button press — and can a
// re-assert win it back?
if let latchIndex = CommandLine.arguments.firstIndex(of: "--latch"),
   CommandLine.arguments.count > latchIndex + 1,
   let latchNote = UInt8(CommandLine.arguments[latchIndex + 1]) {

    var outputPort = MIDIPortRef()
    MIDIOutputPortCreate(client, "GranolaMonitor Out" as CFString, &outputPort)
    var destination = MIDIEndpointRef()
    for index in 0..<MIDIGetNumberOfDestinations() {
        let candidate = MIDIGetDestination(index)
        let name = [kMIDIPropertyDisplayName, kMIDIPropertyName]
            .map { stringProperty(candidate, $0) }.joined(separator: " ")
        if name.localizedCaseInsensitiveContains("SMC-Mixer") { destination = candidate; break }
    }
    guard destination != 0 else { print("no SMC-Mixer output endpoint"); exit(1) }

    func send(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
        if packet != nil { MIDISend(outputPort, destination, &list) }
    }

    print("""

    PHASE A — lighting note \(latchNote) once, then leaving it alone for 8s.
    Do NOT touch the controller. Watch that button.
      -> if it does NOT light, the host cannot drive this LED at all.
      -> if it lights and stays lit, host control works.

    """)
    send([0x90, latchNote, 0x7F])
    Thread.sleep(forTimeInterval: 8)

    print("""
    PHASE B — now re-asserting the LED every 200ms for 12s.
    PRESS AND RELEASE that same button a couple of times.
      -> if it comes back on within a moment of each release, a repeated
         re-assert is the fix.
      -> if it stays dark while you press, the device is locking us out.

    """)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        send([0x90, latchNote, 0x7F])
        Thread.sleep(forTimeInterval: 0.2)
    }
    send([0x90, latchNote, 0x00])
    print("done — what did you see in each phase?")
    exit(0)
}

// --survey lights one representative button per region, 3.5s each, so a single
// run maps which LEDs the host can actually drive.
if CommandLine.arguments.contains("--survey") {
    var outputPort = MIDIPortRef()
    MIDIOutputPortCreate(client, "GranolaMonitor Out" as CFString, &outputPort)
    var destination = MIDIEndpointRef()
    for index in 0..<MIDIGetNumberOfDestinations() {
        let candidate = MIDIGetDestination(index)
        let name = [kMIDIPropertyDisplayName, kMIDIPropertyName]
            .map { stringProperty(candidate, $0) }.joined(separator: " ")
        if name.localizedCaseInsensitiveContains("SMC-Mixer") { destination = candidate; break }
    }
    guard destination != 0 else { print("no SMC-Mixer output endpoint"); exit(1) }

    func send(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
        if packet != nil { MIDISend(outputPort, destination, &list) }
    }

    let probes: [(String, UInt8)] = [
        ("strip 1, 3rd button down  (Rec/Arm 1)", 0),
        ("strip 1, 2nd button down  (Solo 1)", 8),
        ("strip 1, TOP button       (Mute 1)", 16),
        ("strip 1, BOTTOM button    (Select 1)", 24),
        ("bottom row: Bank Left     (RVB)", 46),
        ("bottom row: Rewind        (PAN)", 91),
        ("bottom row: Stop", 93),
        ("bottom row: Play", 94),
        ("bottom row: Cursor Up     (slot 5)", 96)
    ]

    print("""

    Lighting one button at a time for 3.5s each. Do not touch the controller.
    Note down which ones actually light.

    """)
    for (label, note) in probes {
        print("  note \(String(format: "%3d", note))  \(label)")
        fflush(stdout)
        send([0x90, note, 0x7F])
        Thread.sleep(forTimeInterval: 3.5)
        send([0x90, note, 0x00])
        Thread.sleep(forTimeInterval: 0.4)
    }
    print("\ndone — which ones lit?")
    exit(0)
}

if CommandLine.arguments.contains("--leds") {
    var outputPort = MIDIPortRef()
    MIDIOutputPortCreate(client, "GranolaMonitor Out" as CFString, &outputPort)

    var destination = MIDIEndpointRef()
    for index in 0..<MIDIGetNumberOfDestinations() {
        let candidate = MIDIGetDestination(index)
        let name = [kMIDIPropertyDisplayName, kMIDIPropertyName]
            .map { stringProperty(candidate, $0) }.joined(separator: " ")
        if name.localizedCaseInsensitiveContains("SMC-Mixer") { destination = candidate; break }
    }
    guard destination != 0 else {
        print("no SMC-Mixer output endpoint found")
        exit(1)
    }

    func send(_ bytes: [UInt8]) {
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
        if packet != nil { MIDISend(outputPort, destination, &list) }
    }

    let slots: [(String, UInt8)] = [
        ("slot 1  Rewind", 91), ("slot 2  Fast Fwd", 92),
        ("slot 3  Bank Left", 46), ("slot 4  Bank Right", 47),
        ("slot 5  Cursor Up", 96), ("slot 6  Cursor Down", 97),
        ("slot 7  Cursor Left", 98), ("slot 8  Cursor Right", 99)
    ]

    print("Lighting each project-slot button for 1.5s. Watch the controller.\n")
    for (label, note) in slots {
        print("  \(label)  (note \(note)) — ON")
        fflush(stdout)
        send([0x90, note, 0x7F])
        Thread.sleep(forTimeInterval: 1.5)
        send([0x90, note, 0x00])
        Thread.sleep(forTimeInterval: 0.2)
    }
    print("\nNow lighting all eight at once for 4s…")
    for (_, note) in slots { send([0x90, note, 0x7F]); Thread.sleep(forTimeInterval: 0.02) }
    Thread.sleep(forTimeInterval: 4)
    for (_, note) in slots { send([0x90, note, 0x00]); Thread.sleep(forTimeInterval: 0.02) }
    print("done — which ones lit up?")
    exit(0)
}

var port = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "GranolaMonitor In" as CFString, &port) { packetList, _ in
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        withUnsafeBytes(of: packet.data) { raw in
            let length = Int(packet.length)
            var bytes: [UInt8] = []
            for index in 0..<min(length, 256) { bytes.append(raw[index]) }

            var index = 0
            while index < bytes.count {
                let status = bytes[index]
                guard status >= 0x80 else { index += 1; continue }
                let size = (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0 ? 2 : 3
                let slice = Array(bytes[index..<min(index + size, bytes.count)])
                messageCount += 1
                let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[\(stamp())] \(hex.padding(toLength: 10, withPad: " ", startingAt: 0))  \(describe(slice))")
                fflush(stdout)
                index += size
            }
        }
        packet = MIDIPacketNext(&packet).pointee
    }
}

// --device <substring> selects which controller to listen to.
let deviceFilter: String = {
    if let i = CommandLine.arguments.firstIndex(of: "--device"),
       CommandLine.arguments.count > i + 1 { return CommandLine.arguments[i + 1] }
    return "SMC-Mixer"
}()
print("filter: \(deviceFilter)")

var found = false
for index in 0..<MIDIGetNumberOfSources() {
    let source = MIDIGetSource(index)
    let name = [kMIDIPropertyDisplayName, kMIDIPropertyName]
        .map { stringProperty(source, $0) }.joined(separator: " ")
    if name.localizedCaseInsensitiveContains(deviceFilter) {
        MIDIPortConnectSource(port, source, nil)
        print("connected to: \(name)")
        found = true
    }
}

if !found {
    print("SMC-Mixer not found. Pair it in Audio MIDI Setup > MIDI Studio > Bluetooth,")
    print("then run this again. Sources currently visible:")
    for index in 0..<MIDIGetNumberOfSources() {
        print("  - \(stringProperty(MIDIGetSource(index), kMIDIPropertyDisplayName))")
    }
    exit(1)
}

print("""

Listening. Please do the following, pausing between each:

  1. Press and release PLAY            (baseline — confirms DAW mode)
  2. Press and release SHIFT alone
  3. HOLD SHIFT, press REWIND, release both
  4. HOLD SHIFT, press CURSOR UP, release both

If nothing at all appears for steps 2-4, Shift is consumed by the device and
cannot be used as a modifier by the app.

Press Ctrl-C when done.

""")

RunLoop.current.run()
