import Foundation
import AVFoundation

/// Prepares an audio file for the server: works out what scsynth can read
/// directly, transcodes what it can't, and computes the waveform overview the
/// UI draws behind the scrub head.
enum SampleLoader {

    struct Loaded {
        let originalURL: URL
        /// The file scsynth should actually open — the original, or a cached
        /// transcode of it.
        let serverURL: URL
        let duration: Double
        let sampleRate: Double
        let channels: Int
        let waveform: [Float]
    }

    enum LoadError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return detail
            }
        }
    }

    /// Formats libsndfile (and therefore scsynth) opens without help.
    private static let nativeExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "w64", "au", "snd"
    ]

    /// A channel strip is ~110 points wide, so 512 buckets is already about
    /// double the pixels available. 2048 cost four times the drawing for no
    /// visible gain.
    static let waveformResolution = 512

    static func load(_ url: URL) throws -> Loaded {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.unreadable("Could not read “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let frames = file.length
        guard frames > 0 else {
            throw LoadError.unreadable("“\(url.lastPathComponent)” contains no audio.")
        }

        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let duration = Double(frames) / sampleRate

        let peaks = try waveformPeaks(file: file, frames: frames)

        var serverURL = url
        if !nativeExtensions.contains(url.pathExtension.lowercased()) {
            serverURL = try transcode(url, from: file)
        }

        return Loaded(
            originalURL: url,
            serverURL: serverURL,
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            waveform: peaks
        )
    }

    // MARK: - Waveform

    private static func waveformPeaks(file: AVAudioFile, frames: AVAudioFramePosition) throws -> [Float] {
        let format = file.processingFormat
        let bucketCount = waveformResolution
        let framesPerBucket = max(1, Int(frames) / bucketCount)
        let chunkFrames = AVAudioFrameCount(max(framesPerBucket, 8192))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LoadError.unreadable("Out of memory while analysing the sample.")
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(bucketCount)
        var bucketPeak: Float = 0
        var framesInBucket = 0

        file.framePosition = 0
        while file.framePosition < frames {
            try file.read(into: buffer, frameCount: chunkFrames)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let channelCount = Int(buffer.format.channelCount)

            for frame in 0..<count {
                var magnitude: Float = 0
                for channel in 0..<channelCount {
                    magnitude = max(magnitude, abs(channelData[channel][frame]))
                }
                bucketPeak = max(bucketPeak, magnitude)
                framesInBucket += 1
                if framesInBucket >= framesPerBucket {
                    peaks.append(bucketPeak)
                    bucketPeak = 0
                    framesInBucket = 0
                    if peaks.count >= bucketCount { break }
                }
            }
            if peaks.count >= bucketCount { break }
        }
        if framesInBucket > 0 && peaks.count < bucketCount { peaks.append(bucketPeak) }
        file.framePosition = 0

        // A silent-ish file should still be visible rather than a flat line.
        let loudest = peaks.max() ?? 0
        if loudest > 0 && loudest < 0.35 {
            let gain = 0.35 / loudest
            peaks = peaks.map { $0 * gain }
        }
        return peaks
    }

    // MARK: - Transcoding

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Granola/transcodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// scsynth can't open compressed formats, so anything it would refuse is
    /// rendered once to a float WAV in the app cache and used from there.
    private static func transcode(_ url: URL, from source: AVAudioFile) throws -> URL {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)??
            .timeIntervalSince1970 ?? 0
        let key = "\(abs(url.path.hashValue))-\(Int(stamp))"
        let destination = cacheDirectory.appendingPathComponent("\(key).wav")

        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw LoadError.unreadable("Out of memory while converting the sample.")
        }

        source.framePosition = 0
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        source.framePosition = 0
        return destination
    }
}
