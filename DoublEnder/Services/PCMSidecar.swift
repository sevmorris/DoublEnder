import Foundation
import OSLog

/// Crash-recovery sidecar.
///
/// AVAssetWriter streams the user-facing .m4a/.wav, but an .m4a is only
/// playable once `finishWriting()` writes its moov atom. If the process is
/// killed mid-recording (crash, force-quit, power loss) that never happens
/// and the file is unrecoverable. To survive that, we mirror the exact
/// post-limiter mono float samples into a flat raw-PCM file with a tiny
/// self-describing header. Even an abruptly-truncated sidecar re-wraps
/// cleanly into a valid WAV at next launch.
final class PCMSidecar {
    /// Extension appended to the main output path: `Recording.m4a.pcmrec`.
    static let pathExtension = "pcmrec"

    /// 16-byte header: 4-byte magic, Float64 sample rate, UInt32 channels.
    private static let magic: [UInt8] = Array("DEP1".utf8)   // DoublEnder PCM v1
    private static let headerSize = 16
    private static let bytesPerSample = MemoryLayout<Float>.size

    private static let logger = Logger(subsystem: "io.github.sevmorris.DoublEnder", category: "PCMSidecar")

    private let handle: FileHandle
    let url: URL

    /// Sidecar location for a given main output file.
    static func url(for mainOutput: URL) -> URL {
        URL(fileURLWithPath: mainOutput.path + "." + pathExtension)
    }

    /// Main output file a sidecar was mirroring (strip the `.pcmrec`).
    static func mainOutputURL(for sidecar: URL) -> URL {
        sidecar.deletingPathExtension()
    }

    /// Open a fresh sidecar next to `mainOutput` and write its header.
    /// Returns nil on any I/O failure — recording proceeds without the
    /// safety net rather than failing outright.
    init?(mainOutput: URL, sampleRate: Double, channels: UInt32) {
        let url = PCMSidecar.url(for: mainOutput)

        var header = Data(PCMSidecar.magic)
        var rateBits = sampleRate.bitPattern.littleEndian
        var ch = channels.littleEndian
        withUnsafeBytes(of: &rateBits) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { header.append(contentsOf: $0) }

        guard FileManager.default.createFile(atPath: url.path, contents: header),
              let handle = try? FileHandle(forWritingTo: url) else {
            PCMSidecar.logger.error("Failed to open sidecar at \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        // forWritingTo opens at offset 0 without truncating — seek past the
        // header so the first sample write doesn't overwrite it.
        _ = try? handle.seekToEnd()
        self.handle = handle
        self.url = url
    }

    /// Append raw float samples. Best-effort: a failed write degrades the
    /// safety net but must never interrupt the live recording.
    func append(_ pointer: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let data = Data(bytes: pointer, count: frameCount * PCMSidecar.bytesPerSample)
        do {
            try handle.write(contentsOf: data)
        } catch {
            PCMSidecar.logger.error("Sidecar write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Close the handle but keep the file — the main file could not be
    /// finalized, so the sidecar is the only intact copy.
    func close() {
        try? handle.close()
    }

    /// Close and delete — the main file was finalized successfully (or the
    /// user explicitly discarded the take).
    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Recovery

    enum RecoveryError: LocalizedError {
        case badHeader

        var errorDescription: String? {
            switch self {
            case .badHeader: return "The recovery file is missing or corrupt."
            }
        }
    }

    /// Re-wrap a sidecar's raw float PCM into a valid 32-bit-float WAV
    /// alongside it. Streams in 1 MB chunks so multi-hour recordings don't
    /// blow up memory. Returns the recovered WAV URL.
    static func recoverToWAV(sidecarURL: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: sidecarURL)
        defer { try? input.close() }

        guard let header = try input.read(upToCount: headerSize),
              header.count == headerSize,
              Array(header.prefix(4)) == magic else {
            throw RecoveryError.badHeader
        }

        let sampleRate = Double(
            bitPattern: header.subdata(in: 4..<12).withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
        )
        let channels = header.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian

        let totalSize = (try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? NSNumber)?
            .int64Value ?? Int64(headerSize)
        let dataSize = UInt32(max(0, totalSize - Int64(headerSize)))

        let outURL = recoveredWAVURL(for: sidecarURL)
        FileManager.default.createFile(
            atPath: outURL.path,
            contents: wavHeader(sampleRate: sampleRate, channels: channels, dataSize: dataSize)
        )
        let output = try FileHandle(forWritingTo: outURL)
        defer { try? output.close() }
        try output.seekToEnd()

        // `input` is already positioned past the 16-byte header.
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        return outURL
    }

    /// `/dir/Name.m4a.pcmrec` → `/dir/Name (recovered).wav`, de-duplicated.
    private static func recoveredWAVURL(for sidecarURL: URL) -> URL {
        let mainURL = mainOutputURL(for: sidecarURL)            // /dir/Name.m4a
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
