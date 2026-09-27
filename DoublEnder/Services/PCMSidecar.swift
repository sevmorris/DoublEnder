import Foundation
import CoreAudio
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
/// and other PCM layouts are normalized on append, and the channels are mixed
/// to mono the way AVAssetWriter mixes the main file (see
/// `normalizedMonoFloatSamples`). Recovered WAVs are written as 32-bit float
/// for the same reason.
final class PCMSidecar {
    /// Extension appended to the main output path: `Recording.m4a.pcmrec`.
    static let pathExtension = "pcmrec"

    /// Main-file size (bytes) at or below which launch-time cleanup treats a
    /// companion `.m4a`/`.wav` next to an empty sidecar as a stub, and deletes
    /// both. Above it the file is kept. That is not proof it was finalized — a
    /// crashed take passes 8 KB within a third of a second — but with an empty
    /// sidecar it holds the only audio there is, so keeping it is the safe
    /// side. The recovery dialog does not use this: see
    /// `RecoveryModel.isFinishedRecording`.
    static let mainFileValidThresholdBytes: Int64 = 8 * 1024

    /// v1 header: magic + sample rate + channels (legacy, still recovered).
    private static let magicV1: [UInt8] = Array("DEP1".utf8)
    /// v2 header: same fields + payload format code (all new recordings).
    private static let magicV2: [UInt8] = Array("DEP2".utf8)
    private static let headerSizeV1 = 16
    private static let headerSizeV2 = 20
    /// Payload samples are always float32 mono.
    private static let payloadFormatFloat32: UInt32 = 1
    private static let bytesPerSample = MemoryLayout<Float>.size
    /// Flush the sidecar to disk every 512 KB of payload, so a power loss
    /// loses about the last interval: 2.7 s at 48 kHz mono Float32
    /// (192 KB/s), 1.4 s at 96 kHz.
    private static let syncIntervalBytes = 512 * 1024

    private static let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "PCMSidecar")

    private let handle: FileHandle
    /// Serializes sidecar disk I/O off the capture/writer hot path.
    /// `append` is called from `writerQueue` but dispatches writes here so
    /// a slow disk never blocks `AVAssetWriterInput.append`. Under disk
    /// pressure the sidecar can lag the main file by more than one buffer;
    /// `close()` / `discard()` `ioQueue.sync` to flush before the handle closes.
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
        ioQueue.sync { [self] in
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

    /// Append a CMSampleBuffer, mixing any supported PCM layout to mono
    /// Float32 (`normalizedMonoFloatSamples`) before writing.
    func append(sampleBuffer: CMSampleBuffer) {
        guard let mono = Self.normalizedMonoFloatSamples(from: sampleBuffer), !mono.isEmpty else {
            return
        }
        let data = mono.withUnsafeBufferPointer { Data(buffer: $0) }
        ioQueue.async { [self] in
            self.writePayload(data)
        }
    }

    /// Gain AVAssetWriter gives each channel of a left/right pair, or of an
    /// unlabelled pair, when it mixes the source to the mono main file: 1/√2
    /// (0.707, −3 dB), the two summed. Measured on macOS 26.7 and on macOS 15.
    static let stereoPairGain: Float = 1 / Float(2).squareRoot()

    /// Mix capture PCM to mono Float32 the way AVAssetWriter mixes the main
    /// file, for the sidecar payload and the level meter, so the meter shows
    /// the level the file records and a recovered WAV matches the file.
    ///
    /// The output settings ask the writer for one channel, and it makes the
    /// main file mono itself, weighting each source channel by its label in
    /// the format description's channel layout (`writerMixGains`). A layout
    /// whose mix hasn't been measured falls back to `stereoPairGain` for a
    /// pair and, for more channels, to what this did before it followed the
    /// writer: interleaved channels averaged, planar input's channel 0. There
    /// the meter and the file can differ.
    static func normalizedMonoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let encoding: SampleEncoding
        if isFloat, asbd.mBitsPerChannel == 32 {
            encoding = .float32
        } else if isInt, asbd.mBitsPerChannel == 16 {
            encoding = .int16
        } else if isInt, asbd.mBitsPerChannel == 24 {
            encoding = .int24
        } else if isInt, asbd.mBitsPerChannel == 32 {
            encoding = .int32
        } else {
            return nil
        }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        // The AudioBufferList gives each planar channel its own pointer:
        // CoreMedia need not store the planes back to back.
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }
        let listMemory = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listMemory.deallocate() }
        let list = listMemory.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retainedBlock
        ) == noErr else { return nil }

        // The list points into `retainedBlock`, which must outlive the reads.
        return withExtendedLifetime(retainedBlock) { () -> [Float]? in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let bytesPerSample = encoding.bytesPerSample

            // Where each channel's samples start, and the bytes between them.
            var planes: [(start: UnsafeRawPointer, stride: Int)] = []
            var frames = frameCount
            if isNonInterleaved {
                for buffer in buffers {
                    guard let data = buffer.mData else { return nil }
                    planes.append((start: UnsafeRawPointer(data), stride: bytesPerSample))
                    frames = min(frames, Int(buffer.mDataByteSize) / bytesPerSample)
                }
            } else {
                guard let buffer = buffers.first, let data = buffer.mData else { return nil }
                let frameStride = channels * bytesPerSample
                for channel in 0..<channels {
                    planes.append((
                        start: UnsafeRawPointer(data) + channel * bytesPerSample,
                        stride: frameStride
                    ))
                }
                frames = min(frames, Int(buffer.mDataByteSize) / frameStride)
            }
            guard frames > 0, !planes.isEmpty else { return nil }

            let gains = Self.writerMixGains(for: formatDesc, channels: planes.count)
                ?? Self.unmeasuredMixGains(channels: planes.count, planar: isNonInterleaved)
            var mono = [Float](repeating: 0, count: frames)
            for (plane, gain) in zip(planes, gains) where gain != 0 {
                for frame in 0..<frames {
                    mono[frame] += gain * encoding.decode(plane.start + frame * plane.stride)
                }
            }
            return mono
        }
    }

    /// The gain AVAssetWriter's mono mix gives each channel of a source with
    /// this format description, or nil if that layout's mix hasn't been
    /// measured.
    ///
    /// The writer applies CoreAudio's downmix by channel label. Measured on
    /// macOS 15 by writing each layout through it with the app's settings —
    /// `PCMSidecarTests` repeats that on every CI run, so a change in the
    /// writer fails the build — and the stereo pair on macOS 26.7 too:
    ///
    ///   - One channel passes through, whatever its label.
    ///   - No layout on a pair: mixed as left and right.
    ///   - Left, Right: 0.707 each. Tags Stereo, StereoHeadphones and
    ///     Binaural mix the same way.
    ///   - LeftSurround, RightSurround: 0.5. Tag Quadraphonic is L R Ls Rs.
    ///   - Center, Mono, Unknown: 1.
    ///   - Tag MidSide: the mid channel, at 1; the side channel is dropped.
    ///   - Discrete channels map to outputs by number, so only Discrete_0
    ///     reaches the one output channel, at 1. A mic on any other input
    ///     of a device with discrete channels records nothing.
    ///   - Unused: dropped.
    static func writerMixGains(for formatDesc: CMFormatDescription, channels: Int) -> [Float]? {
        guard channels > 1 else { return channels == 1 ? [1] : nil }
        var layoutSize = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(
            formatDesc, sizeOut: &layoutSize
        ) else {
            return channels == 2 ? [stereoPairGain, stereoPairGain] : nil
        }
        let tag = layout.pointee.mChannelLayoutTag
        let gains: [Float]?
        switch tag {
        case kAudioChannelLayoutTag_UseChannelDescriptions:
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            let offset = MemoryLayout<AudioChannelLayout>
                .offset(of: \AudioChannelLayout.mChannelDescriptions) ?? 12
            let stride = MemoryLayout<AudioChannelDescription>.stride
            guard layoutSize >= offset + count * stride else { return nil }
            let descriptions = UnsafeRawPointer(layout) + offset
            let labels = (0..<count).map { index in
                descriptions.load(fromByteOffset: index * stride, as: AudioChannelDescription.self)
                    .mChannelLabel
            }
            gains = labelGains(labels)
        case kAudioChannelLayoutTag_UseChannelBitmap:
            // Bit n of the bitmap is label n + 1, in label order.
            let bits = layout.pointee.mChannelBitmap.rawValue
            gains = labelGains((0..<32).filter { bits & (1 << $0) != 0 }.map { AudioChannelLabel($0 + 1) })
        case kAudioChannelLayoutTag_Stereo,
             kAudioChannelLayoutTag_StereoHeadphones,
             kAudioChannelLayoutTag_Binaural:
            gains = [stereoPairGain, stereoPairGain]
        case kAudioChannelLayoutTag_Quadraphonic:
            gains = [stereoPairGain, stereoPairGain, 0.5, 0.5]
        case kAudioChannelLayoutTag_MidSide:
            gains = [1, 0]
        default:
            if tag & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder, tag & 0xFFFF > 0 {
                gains = [1] + [Float](repeating: 0, count: Int(tag & 0xFFFF) - 1)
            } else {
                gains = nil
            }
        }
        return gains?.count == channels ? gains : nil
    }

    /// `writerMixGains` for a layout given as channel labels, or nil if any
    /// label's gain hasn't been measured.
    private static func labelGains(_ labels: [AudioChannelLabel]) -> [Float]? {
        var gains: [Float] = []
        for label in labels {
            switch label {
            case kAudioChannelLabel_Left, kAudioChannelLabel_Right:
                gains.append(stereoPairGain)
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround:
                gains.append(0.5)
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono, kAudioChannelLabel_Unknown:
                gains.append(1)
            case kAudioChannelLabel_Unused:
                gains.append(0)
            case kAudioChannelLabel_Discrete_0:
                gains.append(1)
            default:
                // Discrete_1 and up: kAudioChannelLabel_Discrete_0 | n.
                guard label & 0xFFFF_0000 == kAudioChannelLabel_Discrete_0 else { return nil }
                gains.append(0)
            }
        }
        return gains
    }

    /// Gains for a layout whose writer mix hasn't been measured: a pair as
    /// left and right; more channels as before this followed the writer.
    private static func unmeasuredMixGains(channels: Int, planar: Bool) -> [Float] {
        switch channels {
        case 1:
            return [1]
        case 2:
            return [stereoPairGain, stereoPairGain]
        default:
            return planar
                ? [1] + [Float](repeating: 0, count: channels - 1)
                : [Float](repeating: 1 / Float(channels), count: channels)
        }
    }

    /// Capture PCM sample formats the mixer reads, little-endian as on macOS.
    private enum SampleEncoding {
        case float32
        case int16
        case int24
        case int32

        var bytesPerSample: Int {
            switch self {
            case .float32, .int32: return 4
            case .int16: return 2
            case .int24: return 3
            }
        }

        /// The sample at `pointer` as a Float, full scale ±1.
        func decode(_ pointer: UnsafeRawPointer) -> Float {
            switch self {
            case .float32:
                return pointer.loadUnaligned(as: Float.self)
            case .int16:
                return Float(pointer.loadUnaligned(as: Int16.self)) / 32768.0
            case .int24:
                // Sign-extend a packed little-endian 24-bit sample.
                let b0 = Int32(pointer.load(fromByteOffset: 0, as: UInt8.self))
                let b1 = Int32(pointer.load(fromByteOffset: 1, as: UInt8.self))
                let b2 = Int32(pointer.load(fromByteOffset: 2, as: UInt8.self))
                var raw = (b2 << 16) | (b1 << 8) | b0
                if raw & 0x800000 != 0 { raw |= Int32(bitPattern: 0xFF000000) }
                return Float(raw) / 8_388_608.0  // 2^23
            case .int32:
                return Float(pointer.loadUnaligned(as: Int32.self)) / Float(Int32.max)
            }
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
        // A torn header (power loss during the mid-take rate rewrite) can leave
        // garbage in the rate field. wavHeader converts it with UInt32(_:),
        // which traps on NaN, infinity, negative, and out-of-range values —
        // reject those here as a bad header so the launch-time recovery scan
        // shows the failure dialog instead of crash-looping the app.
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= Double(UInt32.max) else {
            throw RecoveryError.badHeader
        }
        let channels = header.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        // Same torn-header hazard as the rate field above: a corrupt channel
        // count traps in wavHeader's UInt16 conversions and byteRate multiply.
        guard channels >= 1, channels <= 64 else {
            throw RecoveryError.badHeader
        }

        let totalSize = (try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? NSNumber)?
            .int64Value ?? Int64(headerSize)
        // The WAV's RIFF chunk-size field stores 36 + dataSize in a UInt32, so
        // any payload above UInt32.max − 36 (~4 GiB, ≈6 hours at 48 kHz mono
        // Float32) cannot be represented and would trap on conversion. Reject
        // it as a bad header; the sidecar stays on disk for manual recovery.
        let payloadSize = totalSize - Int64(headerSize)
        guard payloadSize >= 0, payloadSize <= Int64(UInt32.max) - 36 else {
            throw RecoveryError.badHeader
        }
        let dataSize = UInt32(payloadSize)

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
