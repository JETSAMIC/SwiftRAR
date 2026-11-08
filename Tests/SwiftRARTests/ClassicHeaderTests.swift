import XCTest
@testable import SwiftRAR

/// Field-level parsing of FILE_HEAD and EXT_TIME (Reference §3.6, §3.11),
/// and the header CRC16 (§6.2).
final class ClassicHeaderTests: XCTestCase {

    /// FILE_HEAD bytes of the first entry of a one-file fixture archive.
    private func firstFileHeader(_ configure: (inout RAR3FixtureBuilder.File) -> Void = { _ in }) -> [UInt8] {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "greeting.txt", text: "hello, world")
        configure(&builder.files[0])
        let archive = [UInt8](builder.build())
        let start = 7 + 13
        let size = Int(archive[start + 5]) | Int(archive[start + 6]) << 8
        return Array(archive[start..<(start + size)])
    }

    func testParsesFixedFields() throws {
        let header = firstFileHeader {
            $0.hostOS = 3
            $0.ftime = 0x5021_1863
            $0.attributes = 0o100644
        }
        let flags = UInt16(header[3]) | UInt16(header[4]) << 8
        let file = try ClassicFileHeader(header: header, flags: flags)
        XCTAssertEqual(file.packedSize, 12)
        XCTAssertEqual(file.unpackedSize, 12)
        XCTAssertEqual(file.hostOS, 3)
        XCTAssertEqual(file.fileCRC, CRC32.compute(Data("hello, world".utf8)))
        XCTAssertEqual(file.dosTime, 0x5021_1863)
        XCTAssertEqual(file.method, 0x30)
        XCTAssertEqual(file.attributes, 0o100644)
        XCTAssertEqual(file.nameField, Array("greeting.txt".utf8))
        XCTAssertEqual(file.nameEnd, 32 + 12)
        XCTAssertNil(file.extendedTime)
        XCTAssertFalse(file.isDirectory)
    }

    func testLargeFlagCombinesHighWords() throws {
        let header = firstFileHeader {
            $0.flags = 0x0100
            $0.nameBytes = []
            $0.trailer = [2, 0, 0, 0, 3, 0, 0, 0]
        }
        let file = try ClassicFileHeader(header: header, flags: 0x8100)
        XCTAssertEqual(file.packedSize, 2 << 32 | 12)
        XCTAssertEqual(file.unpackedSize, 3 << 32 | 12)
    }

    func testSaltIsSkippedBeforeExtendedTime() throws {
        let header = firstFileHeader {
            $0.flags = 0x1400
            $0.trailer = [UInt8](repeating: 0xEE, count: 8) + [0x00, 0x80]
        }
        let file = try ClassicFileHeader(header: header, flags: 0x9400)
        XCTAssertEqual(file.extendedTime, ExtendedTime(hasModification: true))
    }

    /// Reference §3.11: one sub-second byte is the most significant byte of
    /// the 24-bit fraction; ctime/atime records carry their own DOS time.
    func testExtendedTimeGroups() throws {
        // mtime: present, 1 byte (0x12 → 0x120000); ctime: present, +1 s,
        // DOS time + 2 bytes; atime absent; arctime: present, 0 bytes.
        var reader = FieldReader([0x08, 0x9E, 0x12, 1, 2, 3, 4, 0xAA, 0xBB, 5, 6, 7, 8])
        let ext = try ExtendedTime.parse(&reader)
        XCTAssertTrue(ext.hasModification)
        XCTAssertFalse(ext.modificationExtraSecond)
        XCTAssertEqual(ext.modificationFraction, 0x12_0000)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testFieldsOverrunningHeaderSizeAreMalformed() {
        let header = Array(firstFileHeader().prefix(31))
        XCTAssertThrowsError(try ClassicFileHeader(header: header, flags: 0x8000)) {
            XCTAssertEqual($0 as? RARError, .malformedHeader)
        }
        var long = firstFileHeader()
        long[26] = 0xFF  // NAME_SIZE beyond HEAD_SIZE
        XCTAssertThrowsError(try ClassicFileHeader(header: long, flags: 0x8000)) {
            XCTAssertEqual($0 as? RARError, .malformedHeader)
        }
    }

    /// Reference §6.2 / §3.10: the RAR 3.x end block `C4 3D 7B 00 40 07 00`.
    func testHeaderCRC16OfEndBlock() {
        XCTAssertEqual(UInt16(truncatingIfNeeded: CRC32.compute([0x7B, 0x00, 0x40, 0x07, 0x00] as [UInt8])), 0x3DC4)
        XCTAssertEqual(UInt16(truncatingIfNeeded: CRC32.compute(Data("123456789".utf8))), 0x3926)
    }

    func testDOSTimestampLeapDay() {
        // 2024-02-29 23:59:58 UTC
        let packed: UInt32 = (44 << 25) | (2 << 21) | (29 << 16) | (23 << 11) | (59 << 5) | 29
        XCTAssertEqual(DOSTimestamp.date(packed), Date(timeIntervalSince1970: 1_709_251_198))
        let notLeap: UInt32 = (43 << 25) | (2 << 21) | (29 << 16)
        XCTAssertNil(DOSTimestamp.date(notLeap))
        XCTAssertNil(DOSTimestamp.date((44 << 25) | (1 << 21) | (1 << 16) | 30))  // second 60
    }
}
