import Foundation

/// Canonical-Huffman decoder used by the RAR3 (and many ZIP-family)
/// compressed streams.
///
/// RAR3 transmits Huffman trees as a flat array of code lengths — one
/// length per alphabet symbol, in symbol order, with length zero meaning
/// "this symbol does not appear in the tree". The decoder reconstructs
/// canonical codes from those lengths using the textbook algorithm:
///
///   1. Count how many codes there are of each length (`bl_count`).
///   2. Compute the smallest code of each length so that codes assigned
///      in order are strictly increasing (`next_code`).
///   3. Walk symbols in alphabet order, assigning each non-zero-length
///      symbol the next code of its length.
///
/// Decoding then peeks up to `maxLength` bits from the bit stream and
/// performs a short linear search over the per-length first-code table —
/// fast enough for RAR3's modest alphabet sizes (≤ 299 symbols) without
/// the memory overhead of a full lookup table.
struct RAR3HuffmanDecoder {
    /// Maximum Huffman code length RAR3 emits. The reference encoder
    /// limits trees to 15 bits; we accept up to that.
    static let maxCodeLength = 15

    /// For each length L in 1...maxCodeLength, the numeric value of the
    /// first canonical code of that length.
    private let firstCode: [UInt32]
    /// For each length L, the index into `symbols` where the run of
    /// length-L codes starts.
    private let firstSymbolIndex: [Int]
    /// Symbols in canonical-code order: all length-1 symbols first, then
    /// length-2, etc.
    private let symbols: [UInt16]
    /// Code lengths used (1...maxCodeLength) — guards the decode loop.
    private let lengthsUsed: ClosedRange<Int>?

    /// Build a canonical-Huffman decoder from a code-length table.
    ///
    /// - Parameter codeLengths: One length per alphabet symbol, in symbol
    ///   order. Lengths of zero indicate "absent". Non-zero lengths must
    ///   not exceed `RAR3HuffmanDecoder.maxCodeLength`.
    /// - Throws: `RARError.unsupportedFeature` if the table is malformed.
    init(codeLengths: [UInt8]) throws {
        // 1. bl_count[length] = number of symbols with that length.
        var blCount = [Int](repeating: 0, count: RAR3HuffmanDecoder.maxCodeLength + 1)
        for length in codeLengths {
            let l = Int(length)
            if l < 0 || l > RAR3HuffmanDecoder.maxCodeLength {
                throw RARError.unsupportedFeature("Huffman code length \(l) out of range")
            }
            if l > 0 {
                blCount[l] += 1
            }
        }

        // Pathological inputs: an all-zero table is legal in RAR3 (the
        // alphabet is unused for this block). Mark the decoder as
        // "no symbols decodable" and let the caller handle the situation
        // — they should never actually call `decode` on such a table.
        var anyNonZero = false
        for c in blCount where c > 0 { anyNonZero = true; break }

        // 2. next_code[length] = first canonical code of that length.
        var nextCode = [UInt32](repeating: 0, count: RAR3HuffmanDecoder.maxCodeLength + 1)
        var code: UInt32 = 0
        for bits in 1...RAR3HuffmanDecoder.maxCodeLength {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }

        // Validate: at length L the highest possible code value is
        // 2^L - 1. If next_code exceeds that, the table is over-subscribed.
        for bits in 1...RAR3HuffmanDecoder.maxCodeLength {
            let used = nextCode[bits] + UInt32(blCount[bits])
            if used > (UInt32(1) << bits) {
                throw RARError.unsupportedFeature("over-subscribed Huffman code table")
            }
        }

        // 3. Build the symbol table in canonical order.
        // firstSymbolIndex[L] = index into `symbols` where length-L codes begin.
        var firstSymbolIndex = [Int](repeating: 0, count: RAR3HuffmanDecoder.maxCodeLength + 2)
        var running = 0
        for bits in 1...(RAR3HuffmanDecoder.maxCodeLength + 1) {
            firstSymbolIndex[bits] = running
            if bits <= RAR3HuffmanDecoder.maxCodeLength {
                running += blCount[bits]
            }
        }
        let totalCoded = running

        // Place each symbol at its slot. We track a running pointer per
        // length and advance as we encounter symbols of that length.
        var symbols = [UInt16](repeating: 0, count: totalCoded)
        var cursor = firstSymbolIndex // copy, mutated below
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            let l = Int(length)
            symbols[cursor[l]] = UInt16(symbol)
            cursor[l] += 1
        }

        // Stash firstCode = next_code at the *start* of each length's run
        // (before we placed any symbols). next_code already holds that value.
        self.firstCode = nextCode
        self.firstSymbolIndex = firstSymbolIndex
        self.symbols = symbols

        if anyNonZero {
            var minLen = RAR3HuffmanDecoder.maxCodeLength
            var maxLen = 1
            for bits in 1...RAR3HuffmanDecoder.maxCodeLength {
                if blCount[bits] > 0 {
                    if bits < minLen { minLen = bits }
                    if bits > maxLen { maxLen = bits }
                }
            }
            self.lengthsUsed = minLen...maxLen
        } else {
            self.lengthsUsed = nil
        }
    }

    /// Number of symbols this decoder will ever emit (sum of non-zero
    /// code-length entries).
    var symbolCount: Int { symbols.count }

    /// `true` when the source code-length table was entirely zeros.
    /// Callers that hit this case have a malformed block — decoding
    /// always throws.
    var isEmpty: Bool { lengthsUsed == nil }

    /// Decode one symbol from `stream`.
    ///
    /// Peeks up to `maxCodeLength` bits, finds the smallest length L for
    /// which the peeked prefix is at least `firstCode[L]` and at most
    /// `firstCode[L] + count[L] - 1`, then advances the stream by L bits
    /// and returns the corresponding symbol.
    func decode(_ stream: inout BitStream) throws -> UInt16 {
        guard let used = lengthsUsed else {
            throw RARError.unsupportedFeature("decode against empty Huffman tree")
        }

        // Peek the maximum needed prefix.
        let peeked = stream.peekBits(used.upperBound)

        // For each candidate length, shift the peek down to that many
        // bits and check against the canonical code range.
        for length in used.lowerBound...used.upperBound {
            let shift = used.upperBound - length
            let candidate = peeked >> shift
            let first = firstCode[length]
            // count[length] symbols start at index firstSymbolIndex[length].
            let count = firstSymbolIndex[length + 1] - firstSymbolIndex[length]
            if count == 0 { continue }
            if candidate < first { continue }
            if candidate >= first + UInt32(count) { continue }
            // It's in range — index into the symbol list.
            let index = firstSymbolIndex[length] + Int(candidate - first)
            stream.advance(length)
            return symbols[index]
        }

        // No code matched. This is a corrupt / truncated stream.
        throw RARError.unsupportedFeature("Huffman decode failed — no code matched prefix")
    }
}

// MARK: - RAR3 code-length table decoder

/// RAR3 transmits its four real Huffman tables (main, distance, low-distance,
/// length) as a single flat array of code lengths. That array is itself
/// compressed using a small "pre-tree" Huffman that's described inline as 20
/// fixed-width 4-bit lengths.
///
/// The decoder used by `decodeCodeLengths(from:count:previous:)` reproduces
/// the algorithm in `unpack30.cpp` (clean-room implementation):
///
///   1. Read 20 pre-tree lengths. A length of `15` followed by a 4-bit `0`
///      means "literal length 15"; a length of `15` followed by a non-zero
///      4-bit value `n` means "the next `n+2` pre-tree lengths are zero" and
///      consumes those slots in the pre-tree alphabet itself.
///   2. Build the pre-tree Huffman from those 20 lengths.
///   3. Decode `count` real code-length values, where each pre-tree symbol
///      means:
///        - `0..15`: literal length, but XOR-added to the *previous* table's
///          slot value (modulo 16). The "previous" table is the value of
///          the same code-lengths array from the prior block, or all zeros
///          for the first block.
///        - `16`: repeat the just-emitted code length 3..10 times (read 3
///          extra bits, repeat count = `bits + 3`).
///        - `17`: repeat the just-emitted code length 11..138 times (read 7
///          extra bits, count = `bits + 11`).
///        - `18`: emit zero 3..10 times (read 3 extra bits, count = `bits + 3`).
///        - `19`: emit zero 11..138 times (read 7 extra bits, count = `bits + 11`).
///
/// The signed delta from `previous` is what makes table compression so
/// effective in practice: consecutive blocks tend to use nearly identical
/// trees, so most pre-tree symbols are `0` (literal "no change") and the
/// table comes through as a long zero run.
///
/// - Parameters:
///   - stream: the bit stream positioned at the first pre-tree length nibble.
///   - count: number of code-length values to produce (typically
///     `RAR3Tables.totalCodeLengths`, i.e. 404).
///   - previous: prior block's code lengths used for delta decoding. Pass an
///     array of zeros for the first block.
/// - Returns: the decoded code lengths.
/// - Throws: `RARError.unsupportedFeature` on malformed input.
func decodeRAR3CodeLengths(
    from stream: inout BitStream,
    count: Int,
    previous: [UInt8]
) throws -> [UInt8] {
    let preTreeSize = RAR3Tables.preTreeAlphabetSize

    // 1. Read the 20 pre-tree lengths.
    var preLengths = [UInt8](repeating: 0, count: preTreeSize)
    var index = 0
    while index < preTreeSize {
        let length = UInt8(stream.readBits(4))
        if length == 15 {
            let zeroCount = stream.readBits(4)
            if zeroCount == 0 {
                preLengths[index] = 15
                index += 1
            } else {
                // Insert `zeroCount + 2` zeros into the pre-tree itself.
                // The slot we're standing in (currently 15) becomes the
                // first zero of the run.
                var run = Int(zeroCount) + 2
                while run > 0 && index < preTreeSize {
                    preLengths[index] = 0
                    index += 1
                    run -= 1
                }
            }
        } else {
            preLengths[index] = length
            index += 1
        }
    }

    // 2. Build the pre-tree.
    let preTree = try RAR3HuffmanDecoder(codeLengths: preLengths)

    // 3. Decode `count` code lengths, applying delta XOR against `previous`.
    var result = [UInt8](repeating: 0, count: count)
    var i = 0
    while i < count {
        let symbol = try preTree.decode(&stream)
        switch symbol {
        case 0...15:
            // Literal length, delta-XOR'd against previous block's slot.
            let prev = i < previous.count ? previous[i] : 0
            result[i] = (UInt8(symbol) &+ prev) & 0x0F
            i += 1
        case 16:
            // Repeat the just-emitted length 3..10 times.
            let runLength = Int(stream.readBits(3)) + 3
            // RAR3 nuance: "previous" here means the previously emitted
            // *output* slot, not the previous block's slot. If we have
            // no emitted slot yet, fall back to zero (corrupt but
            // tolerated rather than crashing).
            let value = i > 0 ? result[i - 1] : 0
            var run = runLength
            while run > 0 && i < count {
                result[i] = value
                i += 1
                run -= 1
            }
        case 17:
            // Repeat the just-emitted length 11..138 times.
            let runLength = Int(stream.readBits(7)) + 11
            let value = i > 0 ? result[i - 1] : 0
            var run = runLength
            while run > 0 && i < count {
                result[i] = value
                i += 1
                run -= 1
            }
        case 18:
            // Insert 3..10 zero lengths.
            let runLength = Int(stream.readBits(3)) + 3
            var run = runLength
            while run > 0 && i < count {
                result[i] = 0
                i += 1
                run -= 1
            }
        case 19:
            // Insert 11..138 zero lengths.
            let runLength = Int(stream.readBits(7)) + 11
            var run = runLength
            while run > 0 && i < count {
                result[i] = 0
                i += 1
                run -= 1
            }
        default:
            throw RARError.unsupportedFeature(
                "RAR3 pre-tree emitted symbol \(symbol) outside 0..19"
            )
        }
    }
    return result
}

