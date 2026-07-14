import Foundation

/// Streaming CRC32C (Castagnoli) — the checksum Google Cloud Storage uses for
/// object integrity. Computed incrementally so a multi-GB recording is hashed
/// in one pass without loading it into memory. The Cloud uploader sends this at
/// resumable-upload initiation (GCS server-validates the assembled object) and
/// compares it against the finalize response's `x-goog-hash` (FR-003 integrity).
///
/// Pure arithmetic, no Cloud dependency — lives in the shared tree so the Local
/// test target can validate it against the published standard vectors.
struct CRC32C {
    /// Reflected Castagnoli polynomial (0x1EDC6F41 reflected = 0x82F63B78).
    private static let table: [UInt32] = {
        let poly: UInt32 = 0x82F6_3B78
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : (crc >> 1)
            }
            t[i] = crc
        }
        return t
    }()

    private var crc: UInt32 = 0xFFFF_FFFF

    /// Fold more bytes into the running checksum.
    mutating func update(_ data: Data) {
        var c = crc
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        crc = c
    }

    /// Final 32-bit checksum.
    var checksum: UInt32 { crc ^ 0xFFFF_FFFF }

    /// Base64 of the 4-byte big-endian checksum — the exact form GCS uses in the
    /// `x-goog-hash: crc32c=…` header, so it can be sent and compared verbatim.
    var base64: String {
        var be = checksum.bigEndian
        return withUnsafeBytes(of: &be) { Data($0).base64EncodedString() }
    }

    /// CRC32C of an entire file, streamed in 1 MiB reads. One pass, bounded memory.
    static func base64OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = CRC32C()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            crc.update(chunk)
        }
        return crc.base64
    }
}
