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
