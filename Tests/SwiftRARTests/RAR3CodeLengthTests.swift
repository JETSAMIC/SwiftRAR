import XCTest
@testable import SwiftRAR

/// Coverage for `decodeRAR3CodeLengths` — the function that builds the four
/// real Huffman tables (main, distance, lowDist, length) from RAR3's
/// flat-array-of-lengths representation, RLE-compressed with a 20-symbol
/// pre-tree.
final class RAR3CodeLengthTests: XCTestCase {

    /// A tiny BitWriter that builds a MSB-first byte buffer one bit-field at
    /// a time. The tests use it to synthesise the exact bitstreams the
    /// production code expects to read.
    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var bitsInBuffer: Int = 0

        mutating func write(_ value: UInt32, bits: Int) {
            precondition(bits > 0 && bits <= 32)
            // Shift `value` so its `bits` LSBs sit at the top of a 32-bit
            // window, then OR into the pending buffer at the MSB-aligned
            // position immediately below existing bits.
            let masked = UInt64(value) & ((UInt64(1) << bits) - 1)
            let shift = 64 - bitsInBuffer - bits
            buffer |= masked << shift
            bitsInBuffer += bits
            while bitsInBuffer >= 8 {
                let byte = UInt8((buffer >> 56) & 0xFF)
                bytes.append(byte)
                buffer <<= 8
                bitsInBuffer -= 8
            }
        }

        mutating func flush() {
            if bitsInBuffer > 0 {
                let byte = UInt8((buffer >> 56) & 0xFF)
                bytes.append(byte)
                buffer = 0
                bitsInBuffer = 0
            }
        }
    }

    // MARK: - Pre-tree reader

    /// Smallest end-to-end exercise: a 20-symbol pre-tree where every slot
    /// has length 1 — except that's over-subscribed, so we use only 2
    /// non-zero slots and the rest zero. Then verify decoding a few real
    /// table entries.
    ///
    /// We pre-encode pre-tree lengths as the wire format expects:
    /// `[1, 1, 0, 0, 0, 0, ..., 0]` (20 4-bit values). Length 0 means
    /// "symbol absent". Two length-1 symbols → codes 0 and 1.
    /// In RAR3's wire encoding, `0` is just a 4-bit nibble; consecutive
    /// zeros do *not* trigger the "15 + count" optimisation (that requires
    /// reading a 15 marker first).
    func testPreTreeSinglePassNoZeroRun() throws {
        var w = BitWriter()
        // 20 pre-tree lengths: only symbol 0 and symbol 1 used (length 1).
        // Wire: write 4 bits per slot, MSB-first.
        let preLengths: [UInt8] = [1, 1] + Array(repeating: UInt8(0), count: 18)
        for length in preLengths {
            w.write(UInt32(length), bits: 4)
        }

        // Real code-length table: we'll decode 4 lengths.
        // Pre-tree decodes: 0 → symbol 0 (literal length 0), 1 → symbol 1
        //                   (literal length 1).
        // Bits to encode "0 1 1 0" = symbols [0, 1, 1, 0] giving raw
        // lengths after XOR with previous (=0 for all): [0, 1, 1, 0].
        w.write(0b0_1_1_0, bits: 4)
        w.flush()

        var stream = BitStream(Data(w.bytes))
        let decoded = try decodeRAR3CodeLengths(
            from: &stream,
            count: 4,
            previous: [UInt8](repeating: 0, count: 4)
        )
        XCTAssertEqual(decoded, [0, 1, 1, 0])
    }

    /// Verify the "length 15 + non-zero nibble = insert N+2 zeros into
    /// pre-tree" path. We construct a pre-tree where slot 0 is a literal
    /// length 1, then slot 1 is the magic 15 marker followed by nibble `3`
    /// → insert 5 zeros at slots 1..5, then slot 6 is another length-1
    /// literal, then 13 more slots zero (using literal nibble `0`).
    /// Final pre-tree: lengths[0]=1, lengths[1..5]=0, lengths[6]=1,
    /// lengths[7..19]=0 → two non-zero symbols (0 and 6) with codes 0 and 1.
    func testPreTreeWithZeroRunOptimisation() throws {
        var w = BitWriter()
        w.write(1, bits: 4)             // slot 0: length 1
        w.write(15, bits: 4)            // slot 1 trigger: 15
        w.write(3, bits: 4)             // ZeroCount = 3, fill 3+2 = 5 zeros at slots 1..5
        w.write(1, bits: 4)             // slot 6: length 1
        for _ in 0..<13 {               // slots 7..19: literal zero
            w.write(0, bits: 4)
        }

        // Real table of 2 entries: encode symbols [0, 6] which under
        // length-1 codes give bits "0 1". With previous = [0, 0] the
        // decoded lengths should be [0, 6].
        w.write(0b01, bits: 2)
        w.flush()

        var stream = BitStream(Data(w.bytes))
        let decoded = try decodeRAR3CodeLengths(
            from: &stream,
            count: 2,
            previous: [0, 0]
        )
        XCTAssertEqual(decoded, [0, 6])
    }

    /// Verify the run-length expansion path: pre-tree symbol 19 (long
    /// zero run) inserts `bits + 11` zeros into the real table.
    func testRunLengthExpansionInsertsZeros() throws {
        var w = BitWriter()
        // Pre-tree: only symbol 19 used (length 1) plus symbol 0 (length 1).
        // 0 → "literal length 0" (matches previous, after XOR), 1 → "long zero run"
        // Pre-tree lengths: [1, 0×18, 1] — that's slot 0 = 1 and slot 19 = 1.
        w.write(1, bits: 4)             // slot 0
        for _ in 0..<18 {
            w.write(0, bits: 4)         // slots 1..18
        }
        w.write(1, bits: 4)             // slot 19

        // Decoded stream: symbol 19 + 7 bits "5" → 5+11 = 16 zeros.
        // Bits: pre-tree code for symbol 19 is "1" (the 2nd of 2
        // length-1 codes), followed by 7 bits encoding decimal 5.
        w.write(1, bits: 1)             // pre-tree symbol 19
        w.write(5, bits: 7)             // run length parameter
        w.flush()

        // Need a non-zero `previous` to verify the zero run truly fills
        // zeros rather than copying from previous. Use all-3 previous.
        let previous = [UInt8](repeating: 3, count: 16)
        var stream = BitStream(Data(w.bytes))
        let decoded = try decodeRAR3CodeLengths(
            from: &stream,
            count: 16,
            previous: previous
        )
        XCTAssertEqual(decoded, [UInt8](repeating: 0, count: 16))
    }

    /// The delta-XOR path: a literal pre-tree value of `0` decodes to
    /// "keep the previous block's slot value" (because `(0 + prev) & 0xf
    /// == prev`). Verify this is true.
    func testZeroSymbolPreservesPreviousLength() throws {
        var w = BitWriter()
        // Pre-tree with just symbol 0 (length 1).
        w.write(1, bits: 4)             // slot 0
        for _ in 0..<19 {               // slots 1..19
            w.write(0, bits: 4)
        }

        // Decoded stream: four pre-tree symbol-0s (4 single-bit codes).
        w.write(0, bits: 1)
        w.write(0, bits: 1)
        w.write(0, bits: 1)
        w.write(0, bits: 1)
        w.flush()

        let previous: [UInt8] = [4, 5, 6, 7]
        var stream = BitStream(Data(w.bytes))
        let decoded = try decodeRAR3CodeLengths(
            from: &stream,
            count: 4,
            previous: previous
        )
        XCTAssertEqual(decoded, previous)
    }
}
