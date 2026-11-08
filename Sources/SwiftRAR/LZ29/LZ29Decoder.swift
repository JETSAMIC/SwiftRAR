import Foundation

/// Decoder for the RAR 2.9 LZ bitstream (Reference §6.3) of one
/// self-contained (non-solid) entry.
///
/// Scope: LZ blocks only. A PPMd block header throws
/// ``RARFeature/ppmd`` and a filter record throws ``RARFeature/vmFilter``,
/// so an entry is never returned without its post-processing.
///
/// Hardening: output stops at the declared size, every match distance is
/// checked against the bytes produced so far, every table read is bounded,
/// and each loop iteration consumes input or produces output, so the loop
/// terminates on any input.
struct LZ29Decoder {

    /// Decompress `packed` into exactly `outputSize` bytes.
    ///
    /// - Throws: ``RARError/corruptData`` for invalid codes, tables or
    ///   distances, or a stream that ends before `outputSize` bytes;
    ///   ``RARError/truncated`` when the input runs out mid-symbol;
    ///   ``RARError/unsupportedFeature(_:)`` for PPMd blocks and filters.
    static func decode(_ packed: Data, outputSize: Int) throws -> Data {
        guard outputSize > 0 else { return Data() }
        var decoder = LZ29Decoder(input: [UInt8](packed), outputSize: outputSize)
        try decoder.run()
        return Data(decoder.output)
    }

    // MARK: - State (Reference §6.3.2)

    private var input: MSBBitReader
    private let outputSize: Int
    private var output: [UInt8] = []

    private var previousLengths = [UInt8](repeating: 0, count: LZ29Tables.totalCodeLengths)
    private var mainCode: PrefixCode?
    private var distanceSlotCode: PrefixCode?
    private var lowDistanceCode: PrefixCode?
    private var lengthCode: PrefixCode?

    /// Most recent match distances, newest first.
    private var recentDistances = [0, 0, 0, 0]
    private var lastMatchLength = 0
    private var lowNibble = 0
    private var lowNibbleRepeats = 0

    private init(input: [UInt8], outputSize: Int) {
        self.input = MSBBitReader(input)
        self.outputSize = outputSize
        // Reserve conservatively: the declared size is untrusted.
        let ceiling = input.count > (Int.max - 4096) / 32 ? outputSize : input.count * 32 + 4096
        output.reserveCapacity(min(outputSize, ceiling))
    }

    // MARK: - Main loop (Reference §6.3.8)

    private mutating func run() throws {
        var needTables = true
        while output.count < outputSize {
            if needTables {
                try readBlockHeader()
                needTables = false
            }
            guard let main = mainCode else { throw RARError.corruptData }
            let symbol = try main.decode(&input)

            switch symbol {
            case 0...255:
                output.append(UInt8(symbol))

            case 256:
                if try input.read(1) == 1 {
                    needTables = true
                } else {
                    // End of this entry's data. The following bit only
                    // matters to the next entry of a solid group.
                    if output.count < outputSize { throw RARError.corruptData }
                }

            case 257:
                throw RARError.unsupportedFeature(.vmFilter)

            case 258:
                if lastMatchLength > 0 {
                    try copyMatch(length: lastMatchLength, distance: recentDistances[0])
                }

            case 259...262:
                let slot = symbol - 259
                let distance = recentDistances[slot]
                recentDistances.remove(at: slot)
                recentDistances.insert(distance, at: 0)
                guard let lengths = lengthCode else { throw RARError.corruptData }
                let code = try lengths.decode(&input)
                let length = LZ29Tables.lengthBase[code] + 2
                    + Int(try input.read(LZ29Tables.lengthExtraBits[code]))
                lastMatchLength = length
                try copyMatch(length: length, distance: distance)

            case 263...270:
                let index = symbol - 263
                let distance = LZ29Tables.shortBase[index] + 1
                    + Int(try input.read(LZ29Tables.shortExtraBits[index]))
                remember(distance)
                lastMatchLength = 2
                try copyMatch(length: 2, distance: distance)

            default:  // 271…298
                let code = symbol - 271
                var length = LZ29Tables.lengthBase[code] + 3
                    + Int(try input.read(LZ29Tables.lengthExtraBits[code]))
                let distance = try readExplicitDistance()
                if distance >= 0x2000 { length += 1 }
                if distance >= 0x40000 { length += 1 }
                remember(distance)
                lastMatchLength = length
                try copyMatch(length: length, distance: distance)
            }
        }
    }

    /// Distance of a match coded by symbols 271…298.
    private mutating func readExplicitDistance() throws -> Int {
        guard let slots = distanceSlotCode else { throw RARError.corruptData }
        let slot = try slots.decode(&input)
        let (base, extraBits) = LZ29Tables.distanceSlots[slot]
        var distance = base + 1
        guard extraBits > 0 else { return distance }
        if slot <= 9 {
            return distance + Int(try input.read(extraBits))
        }
        // Slots above 9 send the high bits raw and the low nibble through
        // the low-distance alphabet (or repeat the previous nibble).
        if extraBits > 4 {
            distance += Int(try input.read(extraBits - 4)) << 4
        }
        if lowNibbleRepeats > 0 {
            lowNibbleRepeats -= 1
        } else {
            guard let lows = lowDistanceCode else { throw RARError.corruptData }
            let value = try lows.decode(&input)
            if value == 16 {
                lowNibbleRepeats = 15
            } else {
                lowNibble = value
            }
        }
        return distance + lowNibble
    }

    /// Push a new distance to the front of the history (no de-duplication).
    private mutating func remember(_ distance: Int) {
        recentDistances.removeLast()
        recentDistances.insert(distance, at: 0)
    }

    /// Append `length` bytes copied from `distance` bytes back, stopping at
    /// the declared output size.
    private mutating func copyMatch(length: Int, distance: Int) throws {
        guard distance >= 1, distance <= output.count else { throw RARError.corruptData }
        let count = min(length, outputSize - output.count)
        var source = output.count - distance
        for _ in 0..<count {
            output.append(output[source])
            source += 1
        }
    }

    // MARK: - Block header and tables (Reference §6.3.3, §6.3.5)

    private mutating func readBlockHeader() throws {
        input.alignToByte()
        if try input.read(1) == 1 {
            throw RARError.unsupportedFeature(.ppmd)
        }
        if try input.read(1) == 0 {
            previousLengths = [UInt8](repeating: 0, count: LZ29Tables.totalCodeLengths)
        }

        let preCode = try PrefixCode(lengths: try readPreCodeLengths())
        var lengths = [UInt8](repeating: 0, count: LZ29Tables.totalCodeLengths)
        var index = 0
        while index < lengths.count {
            let symbol = try preCode.decode(&input)
            switch symbol {
            case 0...15:
                lengths[index] = UInt8((symbol + Int(previousLengths[index])) & 0x0F)
                index += 1
            case 16, 17:
                guard index > 0 else { throw RARError.corruptData }
                let run = symbol == 16 ? Int(try input.read(3)) + 3 : Int(try input.read(7)) + 11
                let repeated = lengths[index - 1]
                for _ in 0..<min(run, lengths.count - index) {
                    lengths[index] = repeated
                    index += 1
                }
            default:  // 18, 19: zeros
                let run = symbol == 18 ? Int(try input.read(3)) + 3 : Int(try input.read(7)) + 11
                index += min(run, lengths.count - index)
            }
        }
        previousLengths = lengths

        var start = 0
        func next(_ count: Int) -> ArraySlice<UInt8> {
            defer { start += count }
            return lengths[start..<(start + count)]
        }
        mainCode = try PrefixCode(lengths: next(LZ29Tables.mainSymbols))
        distanceSlotCode = try PrefixCode(lengths: next(LZ29Tables.distanceSlotSymbols))
        lowDistanceCode = try PrefixCode(lengths: next(LZ29Tables.lowDistanceSymbols))
        lengthCode = try PrefixCode(lengths: next(LZ29Tables.lengthSymbols))
        lowNibble = 0
        lowNibbleRepeats = 0
    }

    /// The twenty 4-bit pre-code lengths, with `15, n` meaning `n + 2`
    /// zeros (or a literal 15 when `n` is 0).
    private mutating func readPreCodeLengths() throws -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: LZ29Tables.preCodeSymbols)
        var index = 0
        while index < lengths.count {
            let value = UInt8(try input.read(4))
            if value == 15 {
                let zeros = Int(try input.read(4))
                if zeros == 0 {
                    lengths[index] = 15
                    index += 1
                } else {
                    index += min(zeros + 2, lengths.count - index)
                }
            } else {
                lengths[index] = value
                index += 1
            }
        }
        return lengths
    }
}
