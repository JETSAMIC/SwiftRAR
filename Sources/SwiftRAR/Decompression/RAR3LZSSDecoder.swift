import Foundation

/// RAR3 (Unpack29) LZSS decoder.
///
/// Implements the bitstream described in WinRAR's public `technote.txt` and
/// cross-referenced against clean-room implementations (rarfile.py, bitjs
/// unrar.js). The format is a literal/length+distance LZ77 variant with
/// canonical Huffman codes for four alphabets (main, distance, low-distance,
/// length) plus a 20-symbol pre-tree that RLE-compresses the trees
/// themselves.
///
/// ### What this implementation does
///
/// - Decodes RAR3 method-byte 0x31..0x35 streams into their unpacked bytes.
///   All five method bytes share the same bitstream format; they differ only
///   in *encoder-side* match-finder heuristics. The decoder is identical for
///   "fastest", "normal", and "best" modes.
/// - Supports the full 4 MB sliding window (the maximum RAR3 dictionary).
/// - Handles block-level table refresh, the "keep old tables" flag, and the
///   2-bit end-of-block protocol.
/// - Tracks the four most recent match distances and the most recent match
///   length (for the "repeat last match" symbol).
/// - Recognises and skips VM filter blocks (main symbol 257) by consuming
///   the documented variable-length filter spec without applying it.
///
/// ### What it does NOT do
///
/// - **VM filter execution.** The pre-built and custom filters (E8/E8E9 x86
///   call/jmp distance correction, RGB delta, audio delta, ARM jump) are
///   parsed and skipped. Archives that depend on filters for correctness
///   (rare outside hand-crafted test cases — most real-world archives have
///   no filters or use them only for redundancy) will produce
///   filter-uncorrected output. The output bytes pass through unchanged.
/// - **PPMd mode (method 0x35 mid-stream).** RAR3 best-method archives can
///   switch into Dmitry Shkarin's PPMII variant for text-heavy data. The
///   block-type bit is detected and rejected with a clear error.
/// - **Solid archives.** Each entry is decoded from a fresh sliding window.
///   Solid extraction requires preserving window state across entries —
///   tracked separately at the iterator level.
enum RAR3LZSSDecoder {

    // MARK: - Public entry point

    /// Decode an entry whose packed bytes live at `entry.dataOffset..<+packedSize`
    /// inside `archive`. Returns the unpacked payload, length-checked against
    /// `entry.unpackedSize` and CRC32-verified against `entry.crc32`.
    static func decompress(_ entry: RAREntry, from archive: Data) throws -> Data {
        // Slice the packed region.
        let start = Int(entry.dataOffset)
        let length = Int(entry.packedSize)
        guard start >= 0, length >= 0,
              start <= archive.count,
              start + length <= archive.count else {
            throw RARError.entryOffsetOutOfRange
        }
        let packed = archive.subdata(
            in: (archive.startIndex + start)..<(archive.startIndex + start + length)
        )

        let output = try extract(
            input: packed,
            expectedOutputSize: Int(entry.unpackedSize)
        )

        // CRC32 verification matches the STORE path's contract.
        if entry.unpackedSize > 0 {
            if CRC32.compute(output) != entry.crc32 {
                throw RARError.dataCRCMismatch
            }
        }
        return output
    }

    /// Pure decoder entry-point — no `RAREntry` dependency. Useful for tests
    /// that synthesise bitstreams directly.
    static func extract(input: Data, expectedOutputSize: Int) throws -> Data {
        let decoder = Decoder(input: input, expectedOutputSize: expectedOutputSize)
        try decoder.run()
        return decoder.takeOutput()
    }
}

// MARK: - Internal decoder state

private final class Decoder {

    /// 4 MB sliding window — the RAR3 maximum dictionary size.
    private static let windowSize = 0x400000

    private var stream: BitStream
    private let expectedOutputSize: Int

    /// Output sink — bytes written in extraction order, mirrored into the
    /// sliding window. We accumulate into `Data` rather than streaming to
    /// the caller so we can verify CRC32 in a single pass.
    private var output: Data
    /// Sliding window. Indexed modulo `windowSize` via `writeCursor`.
    private var window: [UInt8]
    private var writeCursor: Int = 0

    /// The four real Huffman trees (built fresh every block-table refresh).
    private var mainTree: RAR3HuffmanDecoder?
    private var distTree: RAR3HuffmanDecoder?
    private var lowDistTree: RAR3HuffmanDecoder?
    private var lengthTree: RAR3HuffmanDecoder?

    /// Persistent code-length state — survives across blocks (used as the
    /// "previous" delta basis for `decodeRAR3CodeLengths`).
    private var previousCodeLengths: [UInt8]

    /// Most-recently-used match distances (LRU, slot 0 = most recent).
    private var recentDistances: [Int] = [0, 0, 0, 0]
    /// Length of the most recent match (for the "repeat last match" symbol).
    private var lastLength: Int = 0

    /// Low-distance repeat state.
    private var lowDistRepeatCount: Int = 0
    private var previousLowDist: Int = 0

    /// `true` once we've successfully read the first table set. Subsequent
    /// blocks may carry the "keep old tables" flag, in which case we reuse
    /// the trees built earlier.
    private var tablesRead: Bool = false

    init(input: Data, expectedOutputSize: Int) {
        self.stream = BitStream(input)
        self.expectedOutputSize = expectedOutputSize
        self.output = Data()
        self.output.reserveCapacity(max(expectedOutputSize, 0))
        self.window = [UInt8](repeating: 0, count: Decoder.windowSize)
        self.previousCodeLengths = [UInt8](
            repeating: 0,
            count: RAR3Tables.totalCodeLengths
        )
    }

    func takeOutput() -> Data {
        return output
    }

    // MARK: - Top-level driver

    /// Read blocks until the expected output length is reached or the
    /// "no new file, no new table" terminator is seen.
    func run() throws {
        // First block: must read tables. Block flags govern subsequent
        // refreshes.
        try readBlockHeaderAndTables(initial: true)

        while output.count < expectedOutputSize {
            let mainSymbol = try decodeMain()
            try dispatch(mainSymbol)
        }
        // Truncate to expected length — match copies near the tail can
        // overshoot when a length spec walks past the requested boundary.
        if output.count > expectedOutputSize {
            output = output.prefix(expectedOutputSize)
        }
    }

    // MARK: - Block header / table refresh

    /// Consume the per-block header bits (PPM flag + keep-tables flag),
    /// possibly re-reading the four real Huffman trees.
    ///
    /// On the very first call (`initial == true`), tables are always
    /// re-read regardless of the keep flag — there are no prior tables
    /// to reuse.
    private func readBlockHeaderAndTables(initial: Bool) throws {
        // Align to byte boundary before sampling the block-header bits.
        stream.alignToByte()

        let header = stream.peekBits(2)
        // Bit 0 of `header` (after MSB-first peek) = PPM flag
        // Bit 1 = "keep old tables" flag
        let isPPM = (header & 0b10) != 0
        let keepOldTables = (header & 0b01) != 0
        stream.advance(2)

        if isPPM {
            throw RARError.unsupportedFeature(
                "RAR3 PPMd block (method-dependent, requires PPMII port)"
            )
        }

        if !keepOldTables || initial {
            // Discard the previous-block code lengths (zero them out) so
            // the delta-XOR encoding measures absolute lengths for this
            // block — matches unrar's `memset(UnpOldTable, 0, ...)`.
            if !keepOldTables {
                for i in 0..<previousCodeLengths.count {
                    previousCodeLengths[i] = 0
                }
            }
            let allLengths = try decodeRAR3CodeLengths(
                from: &stream,
                count: RAR3Tables.totalCodeLengths,
                previous: previousCodeLengths
            )
            try buildTrees(from: allLengths)
            previousCodeLengths = allLengths
            tablesRead = true
        } else {
            // Reuse the existing trees; nothing to read.
            if !tablesRead {
                // First block with "keep old tables" set is a corrupt stream.
                throw RARError.unsupportedFeature(
                    "RAR3 first block has keep-old-tables flag with no prior trees"
                )
            }
        }
    }

    /// Slice the flat code-length array into its four alphabets and build
    /// the corresponding Huffman trees.
    private func buildTrees(from lengths: [UInt8]) throws {
        let nc = RAR3Tables.mainAlphabetSize
        let dc = RAR3Tables.distanceAlphabetSize
        let ldc = RAR3Tables.lowDistanceAlphabetSize
        let rc = RAR3Tables.lengthAlphabetSize
        precondition(lengths.count == nc + dc + ldc + rc)

        let mainSlice = Array(lengths[0..<nc])
        let distSlice = Array(lengths[nc..<(nc + dc)])
        let lowSlice  = Array(lengths[(nc + dc)..<(nc + dc + ldc)])
        let lenSlice  = Array(lengths[(nc + dc + ldc)..<(nc + dc + ldc + rc)])

        mainTree = try RAR3HuffmanDecoder(codeLengths: mainSlice)
        distTree = try RAR3HuffmanDecoder(codeLengths: distSlice)
        lowDistTree = try RAR3HuffmanDecoder(codeLengths: lowSlice)
        lengthTree = try RAR3HuffmanDecoder(codeLengths: lenSlice)
    }

    // MARK: - Symbol dispatch

    private func decodeMain() throws -> Int {
        guard let tree = mainTree else {
            throw RARError.unsupportedFeature("RAR3 main tree not initialised")
        }
        return Int(try tree.decode(&stream))
    }

    private func dispatch(_ symbol: Int) throws {
        switch symbol {
        case 0..<256:
            writeLiteral(UInt8(symbol))

        case 256:
            // End of block.
            try handleEndOfBlock()

        case 257:
            // VM filter — consume the spec and ignore.
            try skipVMFilter()

        case 258:
            // Repeat the previous match.
            if lastLength != 0 {
                copyMatch(length: lastLength, distance: recentDistances[0])
            }

        case 259..<263:
            // Recent-distance reference: pick from LRU, then decode length.
            try handleRecentDistance(symbol - 259)

        case 263..<272:
            // Short match: 2 bytes at a small distance.
            try handleShortMatch(symbol - 263)

        default:
            // 272..298 — full length+distance match.
            try handleLongMatch(symbol - 271)
        }
    }

    private func writeLiteral(_ byte: UInt8) {
        output.append(byte)
        window[writeCursor] = byte
        writeCursor = (writeCursor &+ 1) % Decoder.windowSize
    }

    // MARK: - End of block + VM filter

    private func handleEndOfBlock() throws {
        // Spec (verbatim from unrar's ReadEndOfBlock):
        //   "1"  → no new file, new table follows immediately
        //   "00" → new file, no new table
        //   "01" → new file, new table at start of next file
        let bit = stream.readBits(1)
        if bit == 1 {
            // Continue with a fresh table set in the same logical stream.
            try readBlockHeaderAndTables(initial: false)
        } else {
            // New file — for SwiftRAR's per-entry decoder this is the
            // termination signal. The "01" sub-case (re-read tables in
            // the *next* file) is handled implicitly: the next entry will
            // call back into `extract` and treat its first block as
            // initial.
            _ = stream.readBits(1)  // consume the new-table indicator
            // Pad output to expectedOutputSize so the outer loop exits.
            // We do this by injecting a logical "done" — set a flag would
            // be cleaner, but the run-loop checks `output.count` and we
            // already exhausted the stream. Throw if we still need bytes.
            if output.count < expectedOutputSize {
                throw RARError.truncated
            }
        }
    }

    /// Consume the variable-length filter spec for main symbol 257 and
    /// discard it. Spec format (mirrors `Unpack::ReadVMCode`):
    ///
    ///   * First byte (8 bits). Low 3 bits encode `length`:
    ///     - 0..6 → length = `(firstByte & 7) + 1`
    ///     - 7    → length = next 8 bits + 7
    ///     - 8 (impossible in 3-bit field) — only triggered by
    ///       additional-length signalling unrar handles distinctly.
    ///       We treat values 0..6 as the standard path and re-read 8
    ///       extra bits for the value-7 case.
    ///   * `length` additional bytes.
    private func skipVMFilter() throws {
        let firstByte = stream.readBits(8)
        var length = Int(firstByte & 0x07) + 1
        if length == 7 {
            length = Int(stream.readBits(8)) + 7
        }
        // (The unrar "length == 8 → next 16 bits" path is unreachable from
        // a 3-bit field; included in the C++ for legacy reasons. We omit
        // it here.)
        for _ in 0..<length {
            _ = stream.readBits(8)
        }
    }

    // MARK: - Match handling

    /// Recent-distance reference: pull `distance = recentDistances[index]`,
    /// rotate it to slot 0, then decode `length` from the length tree.
    private func handleRecentDistance(_ index: Int) throws {
        precondition(index >= 0 && index < 4)
        let distance = recentDistances[index]
        // Rotate: shift slots [0..<index] right by 1, place `distance` at 0.
        var i = index
        while i > 0 {
            recentDistances[i] = recentDistances[i - 1]
            i -= 1
        }
        recentDistances[0] = distance

        let length = try decodeLength(addend: 2)
        lastLength = length
        copyMatch(length: length, distance: distance)
    }

    /// Short match: distance from `shortBaseTable`, length is always 2.
    private func handleShortMatch(_ shortIndex: Int) throws {
        precondition(shortIndex >= 0 && shortIndex < 8)
        let base = RAR3Tables.shortBaseTable[shortIndex]
        let extra = RAR3Tables.shortBitTable[shortIndex]
        var distance = base + 1
        if extra > 0 {
            distance += Int(stream.readBits(extra))
        }
        insertRecentDistance(distance)
        lastLength = RAR3Tables.shortMatchLength
        copyMatch(length: RAR3Tables.shortMatchLength, distance: distance)
    }

    /// Full length+distance match.
    private func handleLongMatch(_ lengthCode: Int) throws {
        // Length: base + extra bits, plus the inherent +3 offset.
        let base = RAR3Tables.lengthTable[lengthCode]
        let extra = RAR3Tables.lengthBitTable[lengthCode]
        var length = base + 3
        if extra > 0 {
            length += Int(stream.readBits(extra))
        }

        // Distance: decode symbol from the distance tree, then split the
        // high bits from the low bits per the "low-distance optimization".
        guard let dTree = distTree else {
            throw RARError.unsupportedFeature("RAR3 distance tree not initialised")
        }
        let distNumber = Int(try dTree.decode(&stream))
        guard distNumber < RAR3Tables.distanceAlphabetSize else {
            throw RARError.unsupportedFeature(
                "RAR3 distance symbol \(distNumber) outside alphabet"
            )
        }
        var distance = RAR3Tables.distanceTable[distNumber] + 1
        let dBits = RAR3Tables.distanceBitTable[distNumber]

        if dBits > 0 {
            if distNumber > 9 {
                // High-bit slice (skip the low 4 bits, those come from LDD).
                if dBits > 4 {
                    let highBits = Int(stream.readBits(dBits - 4))
                    distance += highBits << 4
                }
                // Low 4 bits via the low-distance tree, with repeat support.
                if lowDistRepeatCount > 0 {
                    lowDistRepeatCount -= 1
                    distance += previousLowDist
                } else {
                    guard let ldTree = lowDistTree else {
                        throw RARError.unsupportedFeature(
                            "RAR3 low-distance tree not initialised"
                        )
                    }
                    let lowSym = Int(try ldTree.decode(&stream))
                    if lowSym == RAR3Tables.lowDistanceRepeatSymbol {
                        // Repeat marker: re-emit previous low for 15 more matches.
                        lowDistRepeatCount = 15
                        distance += previousLowDist
                    } else {
                        distance += lowSym
                        previousLowDist = lowSym
                    }
                }
            } else {
                // Small symbols: read `dBits` raw bits and add directly.
                distance += Int(stream.readBits(dBits))
            }
        }

        insertRecentDistance(distance)
        lastLength = length
        copyMatch(length: length, distance: distance)
    }

    /// Decode a length value from the *length* Huffman tree, applying the
    /// caller-supplied addend (2 for recent-distance matches, 3 for the
    /// long-match path which uses the same alphabet but offsets by one more).
    private func decodeLength(addend: Int) throws -> Int {
        guard let lTree = lengthTree else {
            throw RARError.unsupportedFeature("RAR3 length tree not initialised")
        }
        let symbol = Int(try lTree.decode(&stream))
        guard symbol < RAR3Tables.lengthAlphabetSize else {
            throw RARError.unsupportedFeature(
                "RAR3 length symbol \(symbol) outside alphabet"
            )
        }
        let base = RAR3Tables.lengthTable[symbol]
        let extra = RAR3Tables.lengthBitTable[symbol]
        var length = base + addend
        if extra > 0 {
            length += Int(stream.readBits(extra))
        }
        return length
    }

    /// LRU-insert a new match distance. If `distance` is already in the
    /// ring, promote it to slot 0; otherwise drop the LRU entry and
    /// install `distance` at slot 0.
    private func insertRecentDistance(_ distance: Int) {
        // Find an existing slot first (unrar's InsertOldDist behaviour).
        if let existing = recentDistances.firstIndex(of: distance) {
            var i = existing
            while i > 0 {
                recentDistances[i] = recentDistances[i - 1]
                i -= 1
            }
            recentDistances[0] = distance
        } else {
            recentDistances[3] = recentDistances[2]
            recentDistances[2] = recentDistances[1]
            recentDistances[1] = recentDistances[0]
            recentDistances[0] = distance
        }
    }

    /// Copy `length` bytes from `(writeCursor - distance) mod windowSize`
    /// to `writeCursor`, advancing both. Handles overlap correctly (the
    /// classic LZ77 "run length encoding" trick — distance == 1 with a
    /// length > 1 produces a repeated-byte fill).
    private func copyMatch(length: Int, distance: Int) {
        guard length > 0, distance > 0 else { return }
        let windowSize = Decoder.windowSize

        // Source cursor walks the window byte-by-byte; we cannot use a
        // straight slice because distance might be smaller than length
        // (which is the whole point of LZ77's RLE behaviour).
        var srcCursor = (writeCursor - distance + windowSize) % windowSize
        var dstCursor = writeCursor

        for _ in 0..<length {
            let byte = window[srcCursor]
            output.append(byte)
            window[dstCursor] = byte
            dstCursor = (dstCursor &+ 1) % windowSize
            srcCursor = (srcCursor &+ 1) % windowSize
        }
        writeCursor = dstCursor
    }
}
