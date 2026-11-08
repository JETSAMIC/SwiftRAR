import XCTest
@testable import SwiftRAR

/// Reference §6.3.1: the compressed stream is read most-significant-bit first.
final class BitReaderTests: XCTestCase {

    func testReadsMostSignificantBitFirst() throws {
        var reader = MSBBitReader([0b1011_0010, 0b0111_1111])
        XCTAssertEqual(try reader.read(1), 1)
        XCTAssertEqual(try reader.read(3), 0b011)
        XCTAssertEqual(try reader.read(6), 0b0010_01)
        XCTAssertEqual(try reader.read(6), 0b11_1111)
        XCTAssertEqual(reader.bitsRemaining, 0)
    }

    func testReadsAcrossByteBoundariesUpTo16Bits() throws {
        var reader = MSBBitReader([0x12, 0x34, 0x56, 0x78, 0x9A])
        XCTAssertEqual(try reader.read(4), 0x1)
        XCTAssertEqual(try reader.read(16), 0x2345)
        XCTAssertEqual(try reader.read(16), 0x6789)
        XCTAssertEqual(try reader.read(4), 0xA)
    }

    func testPeekDoesNotConsumeAndPadsWithZeros() throws {
        var reader = MSBBitReader([0xFF])
        XCTAssertEqual(reader.peek(12), 0xFF0)
        XCTAssertEqual(reader.bitsRemaining, 8)
        try reader.skip(4)
        XCTAssertEqual(reader.peek(8), 0xF0)
    }

    func testConsumingPastTheEndIsTruncation() throws {
        var reader = MSBBitReader([0xAA])
        _ = try reader.read(6)
        XCTAssertThrowsError(try reader.read(3)) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
        XCTAssertThrowsError(try MSBBitReader([]).peekThenRead()) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    func testAlignToByte() throws {
        var reader = MSBBitReader([0xFF, 0x5A])
        reader.alignToByte()
        XCTAssertEqual(reader.bitsRemaining, 16)
        _ = try reader.read(3)
        reader.alignToByte()
        XCTAssertEqual(try reader.read(8), 0x5A)
        reader.alignToByte()
        XCTAssertEqual(reader.bitsRemaining, 0)
    }

    func testReadZeroBitsIsANoOp() throws {
        var reader = MSBBitReader([])
        XCTAssertEqual(try reader.read(0), 0)
    }
}

private extension MSBBitReader {
    func peekThenRead() throws {
        var copy = self
        _ = try copy.read(1)
    }
}
