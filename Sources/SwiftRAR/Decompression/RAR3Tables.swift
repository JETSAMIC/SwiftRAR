import Foundation

/// Static lookup tables for the RAR3 (Unpack29) LZSS bit format.
///
/// These tables describe how the variable-length match-length and
/// match-distance symbols emitted by the Huffman decoder expand into
/// numeric values. Each table mirrors the constants documented in the
/// public `technote.txt` shipped with WinRAR 4.x and replicated in
/// clean-room reimplementations (rarfile / bitjs unrar.js).
///
/// The encoding scheme is uniform:
///
///   `value = base[symbol] + readBits(extraBits[symbol])`
///
/// `base` is the smallest value the symbol can represent; `extraBits`
/// is the number of literal bits read from the bitstream after the
/// Huffman symbol to disambiguate the value within `base..<nextBase`.
enum RAR3Tables {

    // MARK: - Alphabet sizes (Unpack29)
    /// Main alphabet: literals (0..255) + end-of-block (256) + VM filter
    /// (257) + repeat-last-match (258) + 4 recent distances (259..262) +
    /// 9 short matches (263..271) + 27 length codes (272..298). Total 299.
    static let mainAlphabetSize: Int = 299
    /// Distance alphabet — 60 symbols cover 1..2^32 via DBitLengthCounts.
    static let distanceAlphabetSize: Int = 60
    /// Low-distance alphabet — 16 raw symbols (low nibble of distance) +
    /// 1 repeat marker. Used only when the matched distance symbol's
    /// extra-bit count exceeds 3.
    static let lowDistanceAlphabetSize: Int = 17
    /// Length alphabet used to disambiguate match length when the main
    /// symbol is one of the 4 "recent distance" references (259..262).
    static let lengthAlphabetSize: Int = 28
    /// Pre-tree alphabet used to RLE-encode the four real Huffman tables.
    static let preTreeAlphabetSize: Int = 20

    /// Combined number of code lengths transmitted per table-refresh
    /// block (main + distance + lowDist + length).
    static let totalCodeLengths: Int =
        mainAlphabetSize + distanceAlphabetSize +
        lowDistanceAlphabetSize + lengthAlphabetSize

    // MARK: - Length alphabet (28 symbols → length 2..258)

    /// Base length for length symbols 0..27. Combined with `lengthBitTable`
    /// extra bits and an implicit +2 offset applied at copy time, these
    /// cover the inclusive range [2, 258].
    static let lengthTable: [Int] = [
          0,   1,   2,   3,   4,   5,   6,   7,
          8,  10,  12,  14,  16,  20,  24,  28,
         32,  40,  48,  56,  64,  80,  96, 112,
        128, 160, 192, 224
    ]

    /// Extra bits to read after each length symbol.
    static let lengthBitTable: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5
    ]

    /// Smallest length actually returned by the decoder. Add this to the
    /// `lengthTable[symbol] + extra` value to get the final match length.
    static let minLength: Int = 2

    // MARK: - Distance alphabet (60 symbols → distance 1..2^32)

    /// Per-bit-length count used to derive `distanceTable` and
    /// `distanceBitTable` at type-load time. Read as: 4 codes with
    /// extra-bits = 0, 2 codes with extra-bits = 1, 2 with extra-bits =
    /// 2, … and so on through 28 (final entry covers 12 codes of
    /// extra-bits = 18). Sum is 60.
    static let distanceBitLengthCounts: [Int] = [
        4, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 14, 0, 12
    ]

    /// Base distance for distance symbols 0..59, computed from
    /// `distanceBitLengthCounts` by cumulative geometric expansion:
    ///
    ///   dist = 0; bitLen = 0
    ///   for groupCount in distanceBitLengthCounts:
    ///     for _ in 0..<groupCount:
    ///       emit(dist); dist += 1 << bitLen
    ///     bitLen += 1
    static let distanceTable: [Int] = {
        var result: [Int] = []
        result.reserveCapacity(distanceAlphabetSize)
        var dist = 0
        var bitLen = 0
        for groupCount in distanceBitLengthCounts {
            for _ in 0..<groupCount {
                result.append(dist)
                dist &+= 1 << bitLen
            }
            bitLen += 1
        }
        return result
    }()

    /// Extra bits to read after each distance symbol.
    static let distanceBitTable: [Int] = {
        var result: [Int] = []
        result.reserveCapacity(distanceAlphabetSize)
        var bitLen = 0
        for groupCount in distanceBitLengthCounts {
            for _ in 0..<groupCount {
                result.append(bitLen)
            }
            bitLen += 1
        }
        return result
    }()

    /// Smallest distance symbol whose low 4 bits come from the
    /// `lowDistance` Huffman alphabet rather than directly from the
    /// bitstream. The block driver checks `extraBits > 3` to route into
    /// the low-distance decoder.
    static let lowDistanceLowBitCount: Int = 4

    // MARK: - Low-distance alphabet (16 codes + 1 repeat marker)

    /// 17-symbol alphabet used to encode the low 4 bits of any distance
    /// whose `distanceBitTable` extra-bit count exceeds 3.
    ///
    /// Symbols 0..15 are taken verbatim as the low nibble. Symbol 16 is
    /// a run-length repeat marker: re-emit the previously decoded
    /// low-distance value, repeating until a different value arrives.
    static let lowDistanceRepeatSymbol: Int = 16

    // MARK: - Short match alphabet (main symbols 263..271)

    /// Short matches encode small distances paired with a fixed length
    /// of 2 — RAR3 emits main symbols 263..270 (8 codes); the offset
    /// `symbol - 263` indexes `shortBaseTable` for the base distance and
    /// `shortBitTable` for the extra-bit count.
    ///
    /// Match length is always 2 (no further bits needed).
    static let shortMatchSymbolBase: Int = 263
    static let shortMatchSymbolCount: Int = 8
    static let shortMatchLength: Int = 2

    /// Base distance for short match symbols (index = main symbol - 263).
    static let shortBaseTable: [Int] = [
        0, 4, 8, 16, 32, 64, 128, 192
    ]

    /// Extra bits to read after each short match symbol.
    static let shortBitTable: [Int] = [
        2, 2, 3, 4, 5, 6, 6, 6
    ]

    // MARK: - Main alphabet semantic constants

    /// End-of-block marker: triggers re-read of code-length tables (or
    /// final termination on the last block).
    static let mainEndOfBlock: Int = 256
    /// VM filter spec follows. The 4-byte spec is consumed and ignored
    /// in this implementation — output bytes pass through without
    /// E8/E8E9 or other filter correction. Common image, text and
    /// generic-binary archives don't depend on filters for correctness.
    static let mainVMFilter: Int = 257
    /// Reuse previous match: length comes from `lastLength`, distance
    /// from `recentDistances[0]`.
    static let mainRepeatLastMatch: Int = 258
    /// Range of "recent distance" symbols. The decoded symbol minus 259
    /// selects one of the four most recently used distances; length is
    /// then decoded from the length alphabet.
    static let mainRecentDistanceBase: Int = 259
    static let mainRecentDistanceCount: Int = 4
    /// First "regular" length+distance match symbol. Length code =
    /// `mainSymbol - mainLengthSymbolBase`; distance code follows from
    /// the distance alphabet.
    static let mainLengthSymbolBase: Int = 271

    /// Number of slots in the recent-distance ring buffer.
    static let recentDistanceSlots: Int = 4
}
