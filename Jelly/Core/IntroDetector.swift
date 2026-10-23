import Accelerate
import AVFoundation
import Foundation

/// Finds a series' opening without help from the server: the first minutes of two episodes of a season are reduced
/// to audio fingerprints, and the longest stretch both share is the intro – the idea behind Jellyfin's Intro Skipper plugin.
enum IntroDetector {
    static let sampleRate = 11025.0
    private static let frameLength = 2048
    private static let hop = 256
    private static let bands = 33
    /// Seconds between two fingerprints (about 23 ms).
    static let hopSeconds = Double(hop) / sampleRate

    struct Match: Equatable {
        /// Intro in the first and in the second episode, in seconds from the start.
        var first: ClosedRange<Double>
        var second: ClosedRange<Double>
    }

    // MARK: Audio

    /// Decodes an audio file Core Audio can read (the server sends MP3) to mono samples at `sampleRate`.
    static func samples(of file: URL) throws -> [Float] {
        let input = try AVAudioFile(forReading: file)
        let format = input.processingFormat
        guard input.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else { return [] }
        try input.read(into: buffer)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / format.sampleRate) + 4096)
        else { return [] }
        converter.downmix = true
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: Fingerprint

    /// One 32-bit print every 23 ms: for 33 bands between 300 and 2000 Hz, whether the energy difference between
    /// neighbouring bands grows or shrinks from one moment to the next (Haitsma & Kalker). Robust against level changes
    /// and lossy encoding. Quiet moments give 0 and are ignored when comparing.
    static func fingerprint(_ samples: [Float]) -> [UInt32] {
        let count = (samples.count - frameLength) / hop + 1
        guard count > 1, let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(frameLength))), radix: .radix2, ofType: DSPSplitComplex.self)
        else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength, isHalfWindow: false)
        let binWidth = sampleRate / Double(frameLength)
        let edges = (0...bands).map { Int(300 * pow(2000.0 / 300, Double($0) / Double(bands)) / binWidth) }

        var prints = [UInt32](repeating: 0, count: count)
        var loudness = [Float](repeating: 0, count: count)
        var frame = [Float](repeating: 0, count: frameLength)
        var real = [Float](repeating: 0, count: frameLength / 2)
        var imaginary = [Float](repeating: 0, count: frameLength / 2)
        var power = [Float](repeating: 0, count: frameLength / 2)
        var energy = [Float](repeating: 0, count: bands)
        var previous = [Float](repeating: 0, count: bands)

        samples.withUnsafeBufferPointer { samples in
            for index in 0..<count {
                let start = index * hop
                vDSP.multiply(UnsafeBufferPointer(rebasing: samples[start..<start + frameLength]), window, result: &frame)
                real.withUnsafeMutableBufferPointer { real in
                    imaginary.withUnsafeMutableBufferPointer { imaginary in
                        var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                        frame.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(frameLength / 2)) }
                        var result = split
                        fft.forward(input: split, output: &result)
                        vDSP.squareMagnitudes(result, result: &power)
                    }
                }
                for band in 0..<bands {
                    energy[band] = vDSP.sum(power[edges[band]..<max(edges[band + 1], edges[band] + 1)])
                }
                var bits: UInt32 = 0
                for band in 0..<32 where (energy[band] - energy[band + 1]) - (previous[band] - previous[band + 1]) > 0 {
                    bits |= 1 << UInt32(band)
                }
                prints[index] = index == 0 ? 0 : bits
                loudness[index] = vDSP.sum(energy)
                swap(&previous, &energy)
            }
        }
        // Silence and near-silence (30 dB below the typical level) carry no information.
        let typical = loudness.sorted()[count / 2]
        for index in 0..<count where loudness[index] < typical * 0.001 { prints[index] = 0 }
        return prints
    }

    // MARK: Matching

    /// The longest stretch both episodes share, if it lasts between `minimum` and `maximum` seconds.
    static func match(_ first: [UInt32], _ second: [UInt32], minimum: Double = 15, maximum: Double = 180) -> Match? {
        guard !first.isEmpty, !second.isEmpty else { return nil }
        var best: (start: Int, end: Int, offset: Int)?
        for offset in candidateOffsets(first, second) {
            for shift in offset - 2...offset + 2 {
                guard let run = longestRun(first, second, offset: shift) else { continue }
                if best.map({ run.end - run.start > $0.end - $0.start }) ?? true { best = (run.start, run.end, shift) }
            }
        }
        guard let best else { return nil }
        let seconds = Double(best.end - best.start) * hopSeconds
        guard seconds >= minimum, seconds <= maximum else { return nil }
        // Print i covers the samples from i·hop on; its centre is half a frame later.
        let centre = Double(frameLength / 2) / sampleRate
        func time(_ index: Int) -> Double { Double(index) * hopSeconds + centre }
        return Match(first: time(best.start)...time(best.end), second: time(best.start - best.offset)...time(best.end - best.offset))
    }

    /// Shifts at which identical or nearly identical prints line up; the true alignment of a shared intro collects
    /// hundreds of votes, chance alignments only a few.
    private static func candidateOffsets(_ first: [UInt32], _ second: [UInt32]) -> [Int] {
        var positions: [UInt32: [Int32]] = [:]
        for (index, print) in second.enumerated() where print != 0 { positions[print, default: []].append(Int32(index)) }
        var votes = [Int32](repeating: 0, count: first.count + second.count)
        for (index, print) in first.enumerated() where print != 0 {
            for bit in -1..<32 {
                let variant = bit < 0 ? print : print ^ (1 << UInt32(bit))
                // Prints that occur everywhere (sustained tones) say nothing about the alignment.
                guard let matches = positions[variant], matches.count <= 16 else { continue }
                for other in matches { votes[index - Int(other) + second.count] += 1 }
            }
        }
        // Neighbouring shifts belong to the same alignment.
        var smoothed = [Int32](repeating: 0, count: votes.count)
        for index in votes.indices { smoothed[index] = votes[max(0, index - 2)...min(votes.count - 1, index + 2)].reduce(0, +) }
        var offsets: [Int] = []
        for index in smoothed.indices.sorted(by: { smoothed[$0] > smoothed[$1] }) where smoothed[index] >= 12 {
            let offset = index - second.count
            if offsets.allSatisfy({ abs($0 - offset) > 40 }) { offsets.append(offset) }
            if offsets.count == 4 { break }
        }
        return offsets
    }

    /// Longest stretch (indices in `first`) where, at this shift, the prints agree clearly better than chance.
    /// Agreement is averaged over one second; gaps of up to two seconds (a quiet beat, a sound effect) are bridged.
    private static func longestRun(_ first: [UInt32], _ second: [UInt32], offset: Int) -> (start: Int, end: Int)? {
        let lower = max(0, offset)
        let upper = min(first.count, second.count + offset)
        let window = Int(1 / hopSeconds)
        guard upper - lower > window else { return nil }
        // Bit differences per print; unknown (silent) prints count as chance (16 of 32).
        var sums = [Int](repeating: 0, count: upper - lower + 1)
        for index in lower..<upper {
            let a = first[index], b = second[index - offset]
            let distance = a == 0 || b == 0 ? 16 : (a ^ b).nonzeroBitCount
            sums[index - lower + 1] = sums[index - lower] + distance
        }
        let gap = Int(2 / hopSeconds)
        var best: (start: Int, end: Int)?
        var current: (start: Int, end: Int)?
        for index in lower..<upper {
            let from = max(lower, index - window / 2), to = min(upper, index + window / 2)
            let average = Double(sums[to - lower] - sums[from - lower]) / Double(to - from)
            guard average < 10 else { continue }
            if let run = current, index - run.end <= gap {
                current = (run.start, index)
            } else {
                current = (index, index)
            }
            if let run = current, best.map({ run.end - run.start > $0.end - $0.start }) ?? true { best = run }
        }
        return best
    }
}
