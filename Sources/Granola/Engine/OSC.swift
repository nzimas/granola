import Foundation

/// Minimal OSC 1.0 encoder/decoder — everything Granola needs to talk to
/// scsynth, and nothing more.
enum OSCValue {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)

    var typeTag: Character {
        switch self {
        case .int: return "i"
        case .float: return "f"
        case .string: return "s"
        case .blob: return "b"
        }
    }

    var floatValue: Float {
        switch self {
        case .int(let v): return Float(v)
        case .float(let v): return v
        case .string(let s): return Float(s) ?? 0
        case .blob: return 0
        }
    }

    var intValue: Int {
        switch self {
        case .int(let v): return Int(v)
        case .float(let v): return Int(v)
        case .string(let s): return Int(s) ?? 0
        case .blob: return 0
        }
    }

    var stringValue: String {
        switch self {
        case .int(let v): return String(v)
        case .float(let v): return String(v)
        case .string(let s): return s
        case .blob(let d): return "<\(d.count) bytes>"
        }
    }
}

struct OSCMessage {
    let address: String
    let arguments: [OSCValue]

    init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }

    // MARK: - Encoding

    func encoded() -> Data {
        var data = Data()
        data.append(Self.padded(address))

        var tags = ","
        for arg in arguments { tags.append(arg.typeTag) }
        data.append(Self.padded(tags))

        for arg in arguments {
            switch arg {
            case .int(let v):
                data.append(Self.bigEndian(UInt32(bitPattern: v)))
            case .float(let v):
                data.append(Self.bigEndian(v.bitPattern))
            case .string(let s):
                data.append(Self.padded(s))
            case .blob(let b):
                data.append(Self.bigEndian(UInt32(b.count)))
                data.append(b)
                let pad = (4 - (b.count % 4)) % 4
                if pad > 0 { data.append(Data(repeating: 0, count: pad)) }
            }
        }
        return data
    }

    private static func padded(_ string: String) -> Data {
        var bytes = Array(string.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return Data(bytes)
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    // MARK: - Decoding

    /// Parses a datagram. Bundles are flattened into their component messages.
    static func decode(_ data: Data) -> [OSCMessage] {
        var cursor = 0
        return decode(data, &cursor, end: data.count)
    }

    private static func decode(_ data: Data, _ cursor: inout Int, end: Int) -> [OSCMessage] {
        guard cursor < end else { return [] }
        let start = cursor

        if let marker = readString(data, &cursor, end: end), marker == "#bundle" {
            cursor += 8  // time tag; Granola never schedules, so it is ignored
            var messages: [OSCMessage] = []
            while cursor + 4 <= end {
                guard let size = readInt32(data, &cursor, end: end) else { break }
                let elementEnd = min(cursor + Int(size), end)
                messages.append(contentsOf: decode(data, &cursor, end: elementEnd))
                cursor = elementEnd
            }
            return messages
        }

        // Not a bundle — rewind to this element's start and parse as a message.
        cursor = start
        guard let address = readString(data, &cursor, end: end),
              let tags = readString(data, &cursor, end: end),
              tags.hasPrefix(",")
        else { return [] }

        var args: [OSCValue] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let v = readInt32(data, &cursor, end: end) else { return [OSCMessage(address, args)] }
                args.append(.int(v))
            case "f":
                guard let v = readInt32(data, &cursor, end: end) else { return [OSCMessage(address, args)] }
                args.append(.float(Float(bitPattern: UInt32(bitPattern: v))))
            case "s":
                guard let v = readString(data, &cursor, end: end) else { return [OSCMessage(address, args)] }
                args.append(.string(v))
            case "b":
                guard let size = readInt32(data, &cursor, end: end), size >= 0,
                      cursor + Int(size) <= end
                else { return [OSCMessage(address, args)] }
                args.append(.blob(data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + cursor + Int(size)))))
                cursor += Int(size) + ((4 - (Int(size) % 4)) % 4)
            default:
                return [OSCMessage(address, args)]
            }
        }
        return [OSCMessage(address, args)]
    }

    private static func readString(_ data: Data, _ cursor: inout Int, end: Int) -> String? {
        guard cursor < end else { return nil }
        var index = cursor
        while index < end && data[data.startIndex + index] != 0 { index += 1 }
        guard index < end else { return nil }
        let bytes = data.subdata(in: (data.startIndex + cursor)..<(data.startIndex + index))
        cursor = index + 1
        cursor += (4 - (cursor % 4)) % 4
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readInt32(_ data: Data, _ cursor: inout Int, end: Int) -> Int32? {
        guard cursor + 4 <= end else { return nil }
        var value: UInt32 = 0
        for offset in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + cursor + offset])
        }
        cursor += 4
        return Int32(bitPattern: value)
    }
}
