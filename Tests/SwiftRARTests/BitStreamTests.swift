import XCTest
@testable import SwiftRAR

final class BitStreamTests: XCTestCase {

    /// Read a known byte sequence one bit at a time and verify each bit
    /// matches the hand-traced MSB-first expansion.
    func testReadOneBitAtATime() {
        // 0b10110010, 0b01011100  →  1 0 1 1 0 0 1 0  0 1 0 1 1 1 0 0
        let bytes = Data([0b10110010, 0b01011100])
        var stream = BitStream(bytes)
        let expected: [UInt32] = [1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0]
        for (index, want) in expected.enumerated() {
            XCTAssertEqual(stream.readBits(1), want, "bit \(index)")
        }
        XCTAssertTrue(stream.isExhausted)
        // Past-the-end reads yield zero rather than crashing.
        XCTAssertEqual(stream.readBits(8), 0)
    }

    /// Multi-bit reads across byte boundaries assemble bits MSB-first.
    func testReadAcrossByteBoundary() {
        // 0b10110010, 0b01011100
        //  ↑──── first 12 bits ────↑ = 0b101100100101 = 0xB25
        let bytes = Data([0b10110010, 0b01011100])
        var stream = BitStream(bytes)
        XCTAssertEqual(stream.readBits(12), 0xB25)
        // Remaining 4 bits: 0b1100 = 0xC
        XCTAssertEqual(stream.readBits(4), 0xC)
        XCTAssertTrue(stream.isExhausted)
    }

    /// `peekBits` does not advance; subsequent `readBits` returns the same
    /// value.
    func testPeekIsNonDestructive() {
        let bytes = Data([0xAB, 0xCD, 0xEF, 0x01])
        var stream = BitStream(bytes)
        let peeked = stream.peekBits(16)
        XCTAssertEqual(peeked, 0xABCD)
        let read = stream.readBits(16)
        XCTAssertEqual(read, peeked)
        XCTAssertEqual(stream.readBits(16), 0xEF01)
    }

    /// `advance` skips without producing a value.
    func testAdvanceSkipsBits() {
        let bytes = Data([0xFF, 0x00, 0xAA])
        var stream = BitStream(bytes)
        stream.advance(4)               // consume top nibble of 0xFF
        XCTAssertEqual(stream.readBits(4), 0xF)
        stream.advance(8)               // consume 0x00
        XCTAssertEqual(stream.readBits(8), 0xAA)
        XCTAssertTrue(stream.isExhausted)
    }

    /// A 32-bit read returns the full big-endian word.
    func testReadFull32Bits() {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var stream = BitStream(bytes)
        XCTAssertEqual(stream.readBits(32), 0xDEADBEEF)
    }

    /// Reads past the end return zero rather than crashing.
    func testReadPastEndYieldsZero() {
        let bytes = Data([0xFF])
        var stream = BitStream(bytes)
        XCTAssertEqual(stream.readBits(8), 0xFF)
        XCTAssertEqual(stream.readBits(8), 0x00)
        XCTAssertEqual(stream.readBits(16), 0x0000)
        XCTAssertTrue(stream.isExhausted)
    }

    /// Reading zero bits is a no-op that returns zero.
    func testReadZeroBitsIsNoOp() {
        let bytes = Data([0x42])
        var stream = BitStream(bytes)
        XCTAssertEqual(stream.readBits(0), 0)
        XCTAssertEqual(stream.readBits(8), 0x42)
    }
}
