import XCTest
@testable import DoublEnder

/// CRC32C validated against published standard vectors + the GCS base64 form.
final class CRC32CTests: XCTestCase {

    private func crc(_ s: String) -> UInt32 {
        var c = CRC32C()
        c.update(Data(s.utf8))
        return c.checksum
    }
    private func crcBase64(_ s: String) -> String {
        var c = CRC32C()
        c.update(Data(s.utf8))
        return c.base64
    }

    func testStandardVector() {
        // The canonical CRC32C test vector.
        XCTAssertEqual(crc("123456789"), 0xE306_9283)
    }

    func testEmptyInput() {
        XCTAssertEqual(crc(""), 0x0000_0000)
    }

    func testKnownStringVector() {
        XCTAssertEqual(crc("The quick brown fox jumps over the lazy dog"), 0x2262_0404)
    }

    func testBase64MatchesGCSForm() {
        // base64 of the 4-byte big-endian 0xE3069283 — what GCS returns in x-goog-hash.
        XCTAssertEqual(crcBase64("123456789"), "4waSgw==")
        XCTAssertEqual(crcBase64(""), "AAAAAA==")
    }

    func testIncrementalEqualsOneShot() {
        // Folding in pieces must equal hashing the whole buffer at once.
        let full = "the quick brown fox jumps over the lazy dog, twice over"
        var oneShot = CRC32C(); oneShot.update(Data(full.utf8))

        var piecewise = CRC32C()
        let bytes = Array(full.utf8)
        for slice in stride(from: 0, to: bytes.count, by: 7) {
            let end = min(slice + 7, bytes.count)
            piecewise.update(Data(bytes[slice..<end]))
        }
        XCTAssertEqual(oneShot.checksum, piecewise.checksum)
        XCTAssertEqual(oneShot.base64, piecewise.base64)
    }

    func testFileHashMatchesInMemory() throws {
        let data = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crc32c-\(UUID().uuidString).bin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var inMemory = CRC32C(); inMemory.update(data)
        XCTAssertEqual(try CRC32C.base64OfFile(at: url), inMemory.base64)
    }
}
