import Foundation

/// Static lookup tables for the RAR3 LZSS bit format.
///
/// These tables describe how the variable-length match-length and
/// match-distance symbols emitted by the Huffman decoder expand into
/// numeric values. Each table mirrors the constants documented in the
/// public `technote.txt` shipped with WinRAR 4.x, and replicated in
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

    // MARK: - Length alphabet (28 symbols → length 2..258)

    /// Base length for length symbols 0..27. Length codes are decoded
    /// from the "length" (a.k.a. low-length) Huffman tree and combined
    /// with `lengthBitTable` extra bits.
    ///
    /// Final length values cover the inclusive range [2, 258]:
    ///   * Symbols 0..7   → exact lengths 2..9 (0 extra bits each).
    ///   * Symbols 8..27  → run-encoded lengths in geometric steps of
    ///     2, 4, 8 … bits, terminating at base 227 + 5 extra bits = 258.
    static let lengthTable: [Int] = [
          0,   1,   2,   3,   4,   5,   6,   7,
          8,  10,  12,  14,  16,  20,  24,  28,
         32,  40,  48,  56,  64,  80,  96, 112,
        128, 160, 192, 224
    ]

    /// Extra bits to read from the stream after each length symbol to
    /// disambiguate the final length. Sums of `lengthTable[i] + (1 <<
    /// lengthBitTable[i]) - 1` form a contiguous covering of 0..226 with
    /// the final entry stretching to 227 + 31 = 258 (offset by the +2
    /// applied at the call site).
    static let lengthBitTable: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5
    ]

    /// Smallest length actually returned by the decoder. RAR3 disallows
    /// "copy 0 bytes" and "copy 1 byte" matches (the encoder always
    /// chooses a literal in that case), so the smallest value a length
    /// code can produce is 2 — `lengthTable` values are offsets above 2.
    static let minLength: Int = 2

    // MARK: - Distance alphabet (60 symbols → distance 1..2^32)

    /// Base distance for distance symbols 0..59. Combined with the
    /// `distanceBitTable` extra-bit counts these cover the full 32-bit
    /// distance range — although RAR3's 4 MB sliding window means the
    /// effective maximum is 0x400000 (the encoder declines to emit larger
    /// distances). Decoder still accepts the full range to be tolerant of
    /// non-conforming encoders.
    static let distanceTable: [Int] = [
              0,         1,         2,         3,         4,         6,
              8,        12,        16,        24,        32,        48,
             64,        96,       128,       192,       256,       384,
            512,       768,      1024,      1536,      2048,      3072,
           4096,      6144,      8192,     12288,     16384,     24576,
          32768,     49152,     65536,     98304,    131072,    196608,
         262144,    327680,    393216,    458752,    524288,    589824,
         655360,    720896,    786432,    851968,    917504,    983040,
        1048576,   1310720,   1572864,   1835008,   2097152,   2359296,
        2621440,   2883584,   3145728,   3407872,   3670016,   3932160
    ]

    /// Extra bits to read after each distance symbol. The first four
    /// symbols (0..3) are direct: their distance is `distanceTable[i]`
    /// and no extra bits are read. Beyond symbol 3, the extra-bit count
    /// is `(symbol / 2) - 1`, growing in lockstep with `distanceTable`.
    ///
    /// Symbols 16..27 emit 4..7 extra bits *as a contiguous integer* —
    /// the "high bits" of the distance. Symbols 28..59 emit their high
    /// bits via the same direct path but the *low four bits* of the
    /// final distance are sourced from the low-distance Huffman tree
    /// (see `lowDistanceTable`). The driver enforces this split.
    static let distanceBitTable: [Int] = [
         0,  0,  0,  0,  1,  1,  2,  2,
         3,  3,  4,  4,  5,  5,  6,  6,
         7,  7,  8,  8,  9,  9, 10, 10,
        11, 11, 12, 12, 13, 13, 14, 14,
        15, 15, 16, 16, 17, 17, 18, 18,
        19, 19, 20, 20, 21, 21, 22, 22,
        23, 23, 24, 24, 25, 25, 26, 26,
        27, 27, 28, 28
    ]

    /// Smallest distance symbol whose low four bits come from the
    /// `lowDistance` Huffman alphabet rather than directly from the
    /// bitstream. The block driver checks `symbol >= splitDistance` to
    /// route into the low-distance decoder.
    static let lowDistanceSplit: Int = 28

    // MARK: - Low-distance alphabet (16 symbols + 1 repeat marker)

    /// 17-symbol alphabet used to encode the low 4 bits of any distance
    /// whose `distanceBitTable` extra-bit count exceeds 3 (symbol ≥ 28).
    ///
    /// Symbols 0..15 are taken verbatim as the low nibble of the final
    /// distance. Symbol 16 is a run-length repeat marker: it re-uses the
    /// previously decoded low-distance symbol. The block driver tracks
    /// the last low-distance symbol seen across the block.
    static let lowDistanceSymbolCount: Int = 16
    static let lowDistanceRepeatSymbol: Int = 16
    static let lowDistanceAlphabetSize: Int = 17

    // MARK: - Short match alphabet (8 symbols)

    /// Short matches are a RAR3 optimisation for very small match
    /// distances. Distance symbols 0..7 within the *main alphabet*
    /// (mapped through `shortDistanceBase` below) cover the eight most
    /// common short ranges; their lengths come from a fixed mapping:
    ///
    ///   short symbol 0 → length 2, no extra bits
    ///   short symbol 1 → length 3, no extra bits
    ///   short symbol 2 → length 3 + readBits(2)
    ///   short symbol 3 → length 4 + readBits(0)
    ///   short symbol 4 → length 4 + readBits(2)
    ///   short symbol 5 → length 5 + readBits(3)
    ///   short symbol 6 → length 4 + readBits(4)
    ///   short symbol 7 → length 4 + readBits(5)
    ///
    /// Those tables are encoded as base + extra-bits pairs below. The
    /// short alphabet is only consulted for *main* Huffman symbols
    /// 259..262 — the driver maps `mainSymbol - 259` to a short symbol
    /// index.
    static let shortBaseTable: [Int] = [
        0, 4, 8, 16, 32, 64, 128, 192
    ]

    /// Extra bits per short distance symbol. Combined with
    /// `shortBaseTable` these produce distances 0..255 in eight bins.
    static let shortBitTable: [Int] = [
        2, 2, 3, 4, 5, 6, 6, 6
    ]
}
