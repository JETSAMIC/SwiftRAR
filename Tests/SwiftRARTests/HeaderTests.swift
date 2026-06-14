import XCTest
@testable import SwiftRAR

final class HeaderTests: XCTestCase {

    func testParsesMainHeaderFromFixture() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a.txt", text: "alpha")
        let archive = builder.build()

        // MAIN_HEAD begins immediately after the 7-byte MARK_HEAD signature.
        let main = try RAR3MainHeader.parse(archive, at: 7)
        XCTAssertEqual(main.blockOffset, 7)
        XCTAssertEqual(main.headerSize, 13)
        XCTAssertFalse(main.isEncrypted)
        XCTAssertFalse(main.isVolume)
        XCTAssertFalse(main.isSolid)
    }

    func testParsesFileHeaderFromFixture() throws {
        var builder = RAR3FixtureBuilder()
        let payload = Data("hello, world".utf8)
        builder.addStoredFile(name: "greeting.txt", payload: payload)
        let archive = builder.build()

        // FILE_HEAD begins immediately after MAIN_HEAD (offset 7 + 13).
        let fh = try RAR3FileHeader.parse(archive, at: 20)
        XCTAssertEqual(fh.fileName, "greeting.txt")
        XCTAssertEqual(fh.method, 0x30)
        XCTAssertTrue(fh.isStored)
        XCTAssertFalse(fh.isDirectory)
        XCTAssertFalse(fh.isEncrypted)
        XCTAssertEqual(fh.packedSize, UInt64(payload.count))
        XCTAssertEqual(fh.unpackedSize, UInt64(payload.count))
        XCTAssertEqual(fh.crc32, CRC32.compute(payload))
        XCTAssertEqual(fh.packedDataOffset, 20 + fh.headerSize)
    }

    func testParseRejectsTruncatedMainHeader() {
        // Just the MARK_HEAD signature plus a few bytes that aren't a full
        // MAIN_HEAD.
        var data = Data(RARSignature.classicBytes)
        data.append(contentsOf: [0x00, 0x00, 0x73])  // half a header
        XCTAssertThrowsError(try RAR3MainHeader.parse(data, at: 7)) { err in
            XCTAssertEqual(err as? RARError, .truncated)
        }
    }

    func testParseRejectsTruncatedFileHeader() throws {
        // Build a valid archive, then truncate it mid-FILE_HEAD payload.
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "x.bin", payload: Data(repeating: 0xFF, count: 64))
        let full = builder.build()
        let truncated = full.subdata(in: 0..<min(full.count, 30))
        XCTAssertThrowsError(try RAR3FileHeader.parse(truncated, at: 20))
    }

    func testFileHeaderRejectsWrongType() {
        // Synthesise a 7-byte block tagged as 0x73 (MAIN), then try to parse
        // it as a FILE_HEAD — should throw unsupportedFeature.
        let data = Data([
            0x00, 0x00,   // HEAD_CRC
            0x73,         // HEAD_TYPE = MAIN
            0x00, 0x00,   // HEAD_FLAGS
            0x07, 0x00    // HEAD_SIZE = 7
        ])
        XCTAssertThrowsError(try RAR3FileHeader.parse(data, at: 0))
    }
}
