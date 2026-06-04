import Foundation
import CoreMedia
import OSLog

/// Crash-recovery sidecar.
///
/// AVAssetWriter streams the user-facing .m4a/.wav, but an .m4a is only
/// playable once `finishWriting()` writes its moov atom. If the process is
/// killed mid-recording (crash, force-quit, power loss) that never happens
/// and the file is unrecoverable. To survive that, we mirror mono float
/// samples into a flat raw-PCM file with a tiny self-describing header.
/// Even an abruptly-truncated sidecar re-wraps cleanly into a valid WAV
/// at next launch.
///
/// Payload is always IEEE Float32 mono regardless of capture format — Int16
/// and other PCM layouts are normalized on append. Recovered WAVs are
/// written as 32-bit float for the same reason.
final class PCMSidecar {
    /// Extension appended to the main output path: `Recording.m4a.pcmrec`.
    static let pathExtension = "pcmrec"

    /// v1 header: magic + sample rate + channels (legacy, still recovered).
    private static let magicV1: [UInt8] = Array("DEP1".utf8)
    /// v2 header: same fields + payload format code (all new recordings).
    private static let magicV2: [UInt8] = Array("DEP2".utf8)
    private static let headerSizeV1 = 16
    private static let headerSizeV2 = 20
    /// Payload samples are always float32 mono.
    private static let payloadFormatFloat32: UInt32 = 1
    private static let bytesPerSample = MemoryLayout<Float>.size
    /// Flush the sidecar to disk every 512 KB so a power loss loses at
    /// most the last fraction of a second rather than seconds of buffer.
    private static let syncIntervalBytes = 512 * 1024

    private static let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "PCMSidecar")

    private let handle: FileHandle
    /// Serializes all sidecar file I/O so `synchronize()` never blocks the
    /// capture delegate while it holds the writer lock.
    private let ioQueue = DispatchQueue(label: "io.github.sevmorris.DoublEnder.pcmrec-io", qos: .utility)
    let url: URL
    private var sampleRate: Double
    private var bytesSinceSync = 0
    /// Called once, on the first write failure, so AudioEngine can surface
    /// a "crash backup unavailable" warning without polling. Nil if unused.
    var onFirstWriteFailure: (() -> Void)?
    private var reportedWriteFailure = false

    /// Sidecar location for a given main output file.
    static func url(for mainOutput: URL) -> URL {
        URL(fileURLWithPath: mainOutput.path + "." + pathExtension)
    }

    /// Main output file a sidecar was mirroring (strip the `.pcmrec`).
    static func mainOutputURL(for sidecar: URL) -> URL {
        sidecar.deletingPathExtension()
    }

    /// True when the file exists and contains at least one audio sample
    /// beyond the header — header-only orphans are not worth recovering.
    static func hasRecoverableContent(at sidecarURL: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size]) as? Int64 else {
            return false
        }
        return size > Int64(headerSizeV2)
    }

    /// Open a fresh v2 sidecar next to `mainOutput` and write its header.
    /// Returns nil on any I/O failure — recording proceeds without the
    /// safety net rather than failing outright.
    init?(mainOutput: URL, sampleRate: Double, channels: UInt32) {
        let url = PCMSidecar.url(for: mainOutput)
        let header = Self.makeHeaderV2(sampleRate: sampleRate, channels: channels)

        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            PCMSidecar.logger.error("Failed to create sidecar at \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? FileManager.default.removeItem(at: url)
            PCMSidecar.logger.error("Failed to open sidecar at \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        // forWritingTo opens at offset 0 without truncating — seek past the
        // header so the first sample write doesn't overwrite it. If the seek
        // fails the next write would clobber the header, leaving a sidecar
        // whose parser can't read the magic at next launch (unrecoverable),
        // so treat seek failure as an init failure and clean up the orphaned
        // file — same pattern as the FileHandle-failure branch above.
        do {
            try handle.seekToEnd()
        } catch {
            try? FileManager.default.removeItem(at: url)
            PCMSidecar.logger.error("Failed to seek sidecar at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.handle = handle
        self.url = url
        self.sampleRate = sampleRate
    }

    /// Rewrite the header when the first capture buffer confirms a sample
    /// rate different from the provisional value chosen at record start.
    func updateSampleRateIfNeeded(_ sampleRate: Double) {
        guard abs(sampleRate - self.sampleRate) > 0.5 else { return }
        ioQueue.async { [self] in
            self.sampleRate = sampleRate
            let header = Self.makeHeaderV2(sampleRate: sampleRate, channels: 1)
            do {
                try self.handle.seek(toOffset: 0)
                try self.handle.write(contentsOf: header)
                try self.handle.seekToEnd()
            } catch {
                PCMSidecar.logger.error("Sidecar header update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Append raw float samples. Best-effort: a failed write degrades the
    /// safety net but must never interrupt the live recording.
    func append(_ pointer: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let data = Data(bytes: pointer, count: frameCount * PCMSidecar.bytesPerSample)
        ioQueue.async { [self] in
            self.writePayload(data)
        }
    }

    /// Append a CMSampleBuffer, normalizing any supported PCM layout to
    /// mono Float32 before writing.
    func append(sampleBuffer: CMSampleBuffer) {
        guard let mono = Self.normalizedMonoFloatSamples(from: sampleBuffer), !mono.isEmpty else {
            return
        }
        let data = mono.withUnsafeBufferPointer { Data(buffer: $0) }
        ioQueue.async { [self] in
            self.writePayload(data)
        }
    }

    /// Normalize capture PCM to mono Float32 for the sidecar payload.
    static func normalizedMonoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var length = 0
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let ptr = dataPointer else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            return monoFromFloat32(
                ptr: ptr, length: length, channels: channels,
                frameCount: frameCount, isNonInterleaved: isNonInterleaved
            )
        }

        if isInt, asbd.mBitsPerChannel == 16 {
            return monoFromInt16(
                ptr: ptr, length: length, channels: channels,
                frameCount: frameCount, isNonInterleaved: isNonInterleaved
            )
        }

        return nil
    }

    private static func monoFromFloat32(
        ptr: UnsafeMutablePointer<Int8>,
        length: Int,
        channels: Int,
        frameCount: Int,
        isNonInterleaved: Bool
    ) -> [Float]? {
        if isNonInterleaved && channels > 1 {
            let bytesPerChannel = frameCount * MemoryLayout<Float>.size
            guard length >= bytesPerChannel else { return nil }
            return Array(UnsafeBufferPointer(
                start: ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { $0 },
                count: frameCount
            ))
        }

        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        if channels == 1 {
            return Array(UnsafeBufferPointer(
                start: ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 },
                count: floatCount
            ))
        }

        let frames = floatCount / channels
        guard frames > 0 else { return nil }
        let floats = ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
        return (0..<frames).map { f in
            var sum: Float = 0
            for ch in 0..<channels { sum += floats[f * channels + ch] }
            return sum / Float(channels)
        }
    }

    private static func monoFromInt16(
        ptr: UnsafeMutablePointer<Int8>,
        length: Int,
        channels: Int,
        frameCount: Int,
        isNonInterleaved: Bool
    ) -> [Float]? {
        if isNonInterleaved && channels > 1 {
            let bytesPerChannel = frameCount * MemoryLayout<Int16>.size
            guard length >= bytesPerChannel else { return nil }
            let ints = ptr.withMemoryRebound(to: Int16.self, capacity: frameCount) { $0 }
            return (0..<frameCount).map { Float(ints[$0]) / 32768.0 }
        }

        let intCount = length / MemoryLayout<Int16>.size
        guard intCount > 0 else { return nil }
        let ints = ptr.withMemoryRebound(to: Int16.self, capacity: intCount) { $0 }

        if channels == 1 {
            return (0..<intCount).map { Float(ints[$0]) / 32768.0 }
        }

        let frames = intCount / channels
        guard frames > 0 else { return nil }
        return (0..<frames).map { f in
            var sum: Float = 0
            for ch in 0..<channels { sum += Float(ints[f * channels + ch]) / 32768.0 }
            return sum / Float(channels)
        }
    }

    private func writePayload(_ data: Data) {
        do {
            try handle.write(contentsOf: data)
            bytesSinceSync += data.count
            if bytesSinceSync >= Self.syncIntervalBytes {
                try handle.synchronize()
                bytesSinceSync = 0
            }
        } catch {
            PCMSidecar.logger.error("Sidecar write failed: \(error.localizedDescription, privacy: .public)")
            if !reportedWriteFailure {
                reportedWriteFailure = true
                onFirstWriteFailure?()
            }
        }
    }

    /// Close the handle but keep the file — the main file could not be
    /// finalized, so the sidecar is the only intact copy.
    func close() {
        ioQueue.sync {
            try? self.handle.synchronize()
            try? self.handle.close()
        }
    }

    /// Close and delete — the main file was finalized successfully (or the
    /// user explicitly discarded the take).
    func discard() {
        ioQueue.sync {
            try? self.handle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Recovery

    enum RecoveryError: LocalizedError {
        case badHeader
        case emptyPayload

        var errorDescription: String? {
            switch self {
            case .badHeader: return "The recovery file is missing or corrupt."
            case .emptyPayload: return "The recovery file contains no audio data."
            }
        }
    }

    /// Re-wrap a sidecar's raw float PCM into a valid 32-bit-float WAV
    /// alongside it. Streams in 1 MB chunks so multi-hour recordings don't
    /// blow up memory. Returns the recovered WAV URL.
    static func recoverToWAV(sidecarURL: URL) throws -> URL {
        let parsed = try parseHeader(at: sidecarURL)
        guard parsed.dataSize > 0 else { throw RecoveryError.emptyPayload }

        let input = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(parsed.headerSize))

        let outURL = recoveredWAVURL(for: sidecarURL)
        FileManager.default.createFile(
            atPath: outURL.path,
            contents: wavHeader(
                sampleRate: parsed.sampleRate,
                channels: parsed.channels,
                dataSize: parsed.dataSize
            )
        )
        let output = try FileHandle(forWritingTo: outURL)
        defer { try? output.close() }
        try output.seekToEnd()

        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        return outURL
    }

    private struct ParsedHeader {
        let headerSize: Int
        let sampleRate: Double
        let channels: UInt32
        let dataSize: UInt32
    }

    private static func parseHeader(at sidecarURL: URL) throws -> ParsedHeader {
        let input = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? input.close() }

        guard let magic = try input.read(upToCount: 4), magic.count == 4 else {
            throw RecoveryError.badHeader
        }

        let headerSize: Int
        if magic.elementsEqual(magicV1) {
            headerSize = headerSizeV1
        } else if magic.elementsEqual(magicV2) {
            headerSize = headerSizeV2
        } else {
            throw RecoveryError.badHeader
        }

        guard let rest = try input.read(upToCount: headerSize - 4),
              rest.count == headerSize - 4 else {
            throw RecoveryError.badHeader
        }

        var header = magic
        header.append(rest)

        let sampleRate = Double(
            bitPattern: header.subdata(in: 4..<12).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        )
        let channels = header.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian

        let totalSize = (try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? NSNumber)?
            .int64Value ?? Int64(headerSize)
        let dataSize = UInt32(max(0, totalSize - Int64(headerSize)))

        return ParsedHeader(
            headerSize: headerSize,
            sampleRate: sampleRate,
            channels: channels,
            dataSize: dataSize
        )
    }

    /// `/dir/Name.m4a.pcmrec` → `/dir/Name (recovered).wav`, de-duplicated.
    private static func recoveredWAVURL(for sidecarURL: URL) -> URL {
        let mainURL = mainOutputURL(for: sidecarURL)
        let dir = mainURL.deletingLastPathComponent()
        let stem = mainURL.deletingPathExtension().lastPathComponent

        var candidate = dir.appendingPathComponent("\(stem) (recovered).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) (recovered \(n)).wav")
            n += 1
        }
        return candidate
    }

    private static func makeHeaderV2(sampleRate: Double, channels: UInt32) -> Data {
        var header = Data(magicV2)
        var rateBits = sampleRate.bitPattern.littleEndian
        var ch = max(channels, 1).littleEndian
        var formatCode = payloadFormatFloat32.littleEndian
        withUnsafeBytes(of: &rateBits) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &formatCode) { header.append(contentsOf: $0) }
        return header
    }

    /// Canonical 44-byte RIFF/WAVE header for IEEE-float PCM.
    private static func wavHeader(sampleRate: Double, channels: UInt32, dataSize: UInt32) -> Data {
        let bitsPerSample: UInt32 = 32
        let ch = max(channels, 1)
        let byteRate = UInt32(sampleRate) * ch * (bitsPerSample / 8)
        let blockAlign = UInt16(ch * (bitsPerSample / 8))

        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(3 /* WAVE_FORMAT_IEEE_FLOAT */); u16(UInt16(ch))
        u32(UInt32(sampleRate)); u32(byteRate); u16(blockAlign); u16(UInt16(bitsPerSample))
        ascii("data"); u32(dataSize)
        return d
    }
}
