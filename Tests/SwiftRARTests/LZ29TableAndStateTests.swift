import XCTest
@testable import SwiftRAR

/// Table transmission (Reference §6.3.5) and decoder-state rules (§6.3.2,
/// §6.3.8) built bit by bit from the document.
final class LZ29TableAndStateTests: XCTestCase {

    private func decode(_ bits: BitWriter, size: Int) throws -> [UInt8] {
        [UInt8](try LZ29Decoder.decode(bits.finished(), outputSize: size))
    }

    /// Sends the 404 main lengths of `RAR29StreamWriter.tableLengths` with a
    /// pre-code in which symbols 0…15 have 5-bit codes equal to the symbol.
    private func writeMainLengths(_ bits: inout BitWriter) {
        for length in RAR29StreamWriter.tableLengths {
            bits.write(UInt32(length), bits: 5)
        }
    }

    /// `15, n` (n > 0) is a run of n + 2 zero pre-code lengths; `15, 0` is
    /// a literal length of 15.
    func testPreCodeEscapes() throws {
        var bits = BitWriter()
        bits.write(0, bits: 2)                        // LZ block, fresh tables
        for _ in 0..<16 { bits.write(5, bits: 4) }    // symbols 0…15: length 5
        bits.write(15, bits: 4); bits.write(1, bits: 4)   // symbols 16…18: zero
        bits.write(15, bits: 4); bits.write(0, bits: 4)   // symbol 19: length 15
        writeMainLengths(&bits)
        for byte in Array("ok".utf8) { bits.write(UInt32(byte), bits: 9) }
        XCTAssertEqual(try decode(bits, size: 2), Array("ok".utf8))
    }

    /// A zero run that would pass entry 404 is cut at 404.
    func testRunsAreClippedAtTheEndOfTheTable() throws {
        var bits = BitWriter()
        bits.write(0, bits: 2)
        for _ in 0..<20 { bits.write(5, bits: 4) }    // all pre-code symbols: 5 bits
        for length in RAR29StreamWriter.tableLengths.dropLast() {
            bits.write(UInt32(length), bits: 5)
        }
        bits.write(19, bits: 5); bits.write(127, bits: 7)  // 138 zeros, 1 slot left
        bits.write(UInt32(Character("z").asciiValue!), bits: 9)
        XCTAssertEqual(try decode(bits, size: 1), Array("z".utf8))
    }

    func testRepeatPreviousAtFirstEntryIsCorrupt() {
        var bits = BitWriter()
        bits.write(0, bits: 2)
        for _ in 0..<20 { bits.write(5, bits: 4) }
        bits.write(16, bits: 5); bits.write(0, bits: 3)
        bits.write(0, bits: 32)
        XCTAssertThrowsError(try decode(bits, size: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    /// RAR/WinRAR 3.x streams normally stop when the declared size is
    /// reached, without an end-of-block symbol (Reference §6.3.8.1, §7.9).
    func testEntryEndsAtDeclaredSizeWithoutEndMarker() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("abc".utf8))
        XCTAssertEqual([UInt8](try LZ29Decoder.decode(w.finished(), outputSize: 3)), Array("abc".utf8))
    }

    private func prefix() -> [UInt8] {
        var rng = SplitMix64(seed: 99)
        return (0..<300).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    private func expected(_ prefix: [UInt8], distances: [Int]) -> [UInt8] {
        var out = prefix
        for d in distances {
            for _ in 0..<3 { out.append(out[out.count - d]) }
        }
        return out
    }

    /// Low-distance symbol 16 reuses the previous nibble for this match and
    /// the next 15 matches that need one; those read no low-distance symbol.
    func testLowDistanceRepeatCoversFifteenFurtherMatches() throws {
        let start = prefix()
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(start)
        func match(slot: Int, high: UInt32?, low: UInt32?) {
            w.bits.write(271, bits: 9)                 // length code 0 → 3
            w.bits.write(UInt32(slot), bits: 6)
            if let high { w.bits.write(high, bits: 1) }
            if let low { w.bits.write(low, bits: 5) }
        }
        var distances: [Int] = []
        match(slot: 10, high: nil, low: 5); distances.append(33 + 5)
        match(slot: 10, high: nil, low: 16); distances.append(33 + 5)
        for _ in 0..<15 {
            match(slot: 12, high: 1, low: nil); distances.append(65 + 16 + 5)
        }
        match(slot: 10, high: nil, low: 2); distances.append(33 + 2)
        let want = expected(start, distances: distances)
        XCTAssertEqual(try decode(w.bits, size: want.count), want)
    }

    /// Reading tables resets the previous nibble and the repeat counter.
    func testTableReadResetsLowDistanceState() throws {
        let start = prefix()
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(start)
        var distances: [Int] = []
        w.bits.write(271, bits: 9); w.bits.write(10, bits: 6); w.bits.write(7, bits: 5)
        distances.append(33 + 7)
        w.bits.write(271, bits: 9); w.bits.write(10, bits: 6); w.bits.write(16, bits: 5)
        distances.append(33 + 7)                       // 15 repeats now pending
        w.newTablesFollow(keep: true)
        w.bits.write(271, bits: 9); w.bits.write(10, bits: 6); w.bits.write(16, bits: 5)
        distances.append(33 + 0)                       // nibble was reset to 0
        let want = expected(start, distances: distances)
        XCTAssertEqual(try decode(w.bits, size: want.count), want)
    }
}
