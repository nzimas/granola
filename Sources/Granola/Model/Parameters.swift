import Foundation

/// Every automatable per-track control, in one table.
///
/// Keeping the specs in a single place is what lets the encoder macro, the
/// randomiser, preset save/load and the UI all stay generic — none of them
/// needs to know what a parameter *means*, only how to map 0…1 onto it.
enum ParamID: String, CaseIterable, Codable, Identifiable {
    case position
    case grainSize
    case density
    case jitter
    case pitch
    case pitchJitter
    case pitchQuant
    case scan
    case drift
    case spread
    case pan
    case lpf
    case hpf
    case resonance
    case filter
    case reverse
    case freeze
    case posLag
    case level
    case reverbSend
    case delaySend

    var id: String { rawValue }

    /// The control name in the `granolaVoice` / `granolaStrip` SynthDef.
    var oscKey: String {
        switch self {
        case .position: return "pos"
        case .level: return "amp"
        default: return rawValue
        }
    }

    /// `granolaStrip` owns level, mute and the two sends; everything else is
    /// the voice.
    var target: ParamTarget {
        switch self {
        case .level, .reverbSend, .delaySend: return .strip
        default: return .voice
        }
    }
}

enum ParamTarget { case voice, strip }

enum ParamCurve: Equatable {
    case linear
    case exponential
    case toggle
    /// `t^exponent`. Exponential mapping needs a non-zero floor, which forces
    /// a parameter that should reach true zero to spend most of its travel in
    /// values too small to hear. A power curve starts at zero, keeps fine
    /// resolution near the bottom, and still spreads the top evenly.
    case power(Double)
}

struct ParamSpec {
    let label: String
    let short: String
    let min: Double
    let max: Double
    let defaultValue: Double
    let curve: ParamCurve
    let unit: String
    /// Excluded from "randomise" — randomising the scrub head or the output
    /// level is never what anyone means by that button.
    let randomisable: Bool

    init(_ label: String, short: String, min: Double, max: Double, `default`: Double,
         curve: ParamCurve = .linear, unit: String = "", randomisable: Bool = true) {
        self.label = label
        self.short = short
        self.min = min
        self.max = max
        self.defaultValue = `default`
        self.curve = curve
        self.unit = unit
        self.randomisable = randomisable
    }

    func value(fromNormalized t: Double) -> Double {
        let t = t.clamped(0, 1)
        switch curve {
        case .linear:
            return min + (max - min) * t
        case .exponential:
            let lo = Swift.max(min, 1e-6)
            return lo * pow(max / lo, t)
        case .power(let exponent):
            return min + (max - min) * pow(t, exponent)
        case .toggle:
            return t >= 0.5 ? 1 : 0
        }
    }

    func normalized(fromValue value: Double) -> Double {
        let v = value.clamped(min, max)
        switch curve {
        case .linear:
            return max > min ? (v - min) / (max - min) : 0
        case .exponential:
            let lo = Swift.max(min, 1e-6)
            return log(Swift.max(v, lo) / lo) / log(max / lo)
        case .power(let exponent):
            guard max > min else { return 0 }
            return pow((v - min) / (max - min), 1 / exponent)
        case .toggle:
            return v >= 0.5 ? 1 : 0
        }
    }

    func format(_ value: Double) -> String {
        switch curve {
        case .toggle:
            return value >= 0.5 ? "on" : "off"
        default:
            break
        }
        let magnitude = Swift.abs(value)
        let digits: Int = magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f%@", value, unit.isEmpty ? "" : " \(unit)")
    }
}

extension ParamID {
    var spec: ParamSpec {
        switch self {
        case .position:
            return ParamSpec("Position", short: "POS", min: 0, max: 1, default: 0,
                             unit: "", randomisable: false)
        case .grainSize:
            return ParamSpec("Grain Size", short: "SIZE", min: 0.002, max: 2.0, default: 0.12,
                             curve: .exponential, unit: "s")
        case .density:
            return ParamSpec("Density", short: "DENS", min: 0.2, max: 200, default: 20,
                             curve: .exponential, unit: "/s")
        // A share of the loaded sample rather than a fixed number of seconds,
        // so the same knob position scatters the same *proportion* of a
        // half-second hit and a ten-second field recording. The cubic curve
        // keeps millisecond scatter reachable at the bottom while spreading the
        // rest of the travel evenly — as seconds on an exponential curve, four
        // fifths of the rotation did nothing audible and the last fifth jumped
        // straight to the whole file.
        case .jitter:
            return ParamSpec("Scatter", short: "JIT", min: 0, max: 100, default: 0.6,
                             curve: .power(3), unit: "%")
        case .pitch:
            return ParamSpec("Pitch", short: "PITCH", min: -24, max: 24, default: 0, unit: "st")
        case .pitchJitter:
            return ParamSpec("Pitch Spray", short: "P.SPR", min: 0, max: 24, default: 0, unit: "st")
        case .pitchQuant:
            return ParamSpec("Quantise Pitch", short: "QUANT", min: 0, max: 1, default: 0, curve: .toggle)
        case .scan:
            return ParamSpec("Scan", short: "SCAN", min: -2, max: 2, default: 0, unit: "x")
        case .drift:
            return ParamSpec("Drift", short: "DRIFT", min: 0, max: 1, default: 0.1)
        case .spread:
            return ParamSpec("Stereo Spread", short: "SPRD", min: 0, max: 1, default: 0.6)
        case .pan:
            // Left out of randomise: tracks start centred and stereo placement
            // is a deliberate choice, so a dice roll should not move it.
            return ParamSpec("Pan", short: "PAN", min: -1, max: 1, default: 0,
                             randomisable: false)
        case .lpf:
            return ParamSpec("Low Pass", short: "LPF", min: 100, max: 20000, default: 18000,
                             curve: .exponential, unit: "Hz")
        case .hpf:
            return ParamSpec("High Pass", short: "HPF", min: 20, max: 8000, default: 20,
                             curve: .exponential, unit: "Hz")
        case .resonance:
            return ParamSpec("Resonance", short: "RES", min: 0, max: 0.95, default: 0)
        // One knob, centre-neutral: down for low-pass, up for high-pass, with
        // resonance rising toward either extreme. Left out of randomise — it is
        // a performance control, and a dice roll should not filter a track.
        case .filter:
            return ParamSpec("DJ Filter", short: "FILT", min: -1, max: 1, default: 0,
                             randomisable: false)
        case .reverse:
            return ParamSpec("Reverse", short: "REV", min: 0, max: 1, default: 0, curve: .toggle)
        case .freeze:
            return ParamSpec("Freeze", short: "FRZ", min: 0, max: 1, default: 0, curve: .toggle)
        case .posLag:
            return ParamSpec("Glide", short: "GLIDE", min: 0.001, max: 2.0, default: 0.05,
                             curve: .exponential, unit: "s", randomisable: false)
        case .level:
            return ParamSpec("Level", short: "LEVEL", min: 0, max: 1.4, default: 0.7,
                             randomisable: false)
        // Sends start at zero on every track and stay out of randomise: the
        // effect mix is a deliberate choice, not something to roll dice on.
        case .reverbSend:
            return ParamSpec("Reverb Send", short: "RVB", min: 0, max: 1, default: 0,
                             randomisable: false)
        case .delaySend:
            return ParamSpec("Delay Send", short: "DLY", min: 0, max: 1, default: 0,
                             randomisable: false)
        }
    }
}

/// The four parameters wired to the SMC-Mixer's per-strip buttons, top to
/// bottom, as specified by the hardware layout.
enum MacroSlot: Int, CaseIterable, Identifiable {
    case grainSize = 0
    case density = 1
    case jitter = 2
    case pitch = 3

    var id: Int { rawValue }

    var param: ParamID {
        switch self {
        case .grainSize: return .grainSize
        case .density: return .density
        case .jitter: return .jitter
        case .pitch: return .pitch
        }
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
