/// A canonical prefix code defined by one code length per symbol
/// (Reference §6.3.4).
///
/// Codes of up to ``lookupBits`` bits are resolved with a single table
/// lookup; longer codes fall back to a length-by-length canonical search.
struct PrefixCode {
    /// Longest code length RAR 2.9 can transmit.
    static let maxLength = 15
    /// Width of the direct lookup table.
    private static let lookupBits = 9

    /// Number of symbols of each length (index 0 unused).
    private var countPerLength = [Int](repeating: 0, count: maxLength + 1)
    /// Used symbols ordered by (length, symbol).
    private var orderedSymbols: [UInt16] = []
    /// `symbol << 4 | length` for every `lookupBits`-bit prefix that starts
    /// with a code of at most `lookupBits` bits; `0` otherwise.
    private var lookup = [UInt16](repeating: 0, count: 1 << lookupBits)

    /// Build the code.
    ///
    /// - Parameter lengths: Code length per symbol; 0 marks an unused symbol.
    /// - Throws: ``RARError/corruptData`` if a length exceeds 15 or the
    ///   lengths over-subscribe the code space. Incomplete codes are allowed.
    init<C: Collection>(lengths: C) throws where C.Element == UInt8 {
        for length in lengths where length > 0 {
            guard Int(length) <= Self.maxLength else { throw RARError.corruptData }
            countPerLength[Int(length)] += 1
        }
        var unassigned = 1
        for length in 1...Self.maxLength {
            unassigned = unassigned * 2 - countPerLength[length]
            guard unassigned >= 0 else { throw RARError.corruptData }
        }

        var nextCode = [Int](repeating: 0, count: Self.maxLength + 1)
        var startIndex = [Int](repeating: 0, count: Self.maxLength + 1)
        var code = 0
        var index = 0
        for length in 1...Self.maxLength {
            code = (code + countPerLength[length - 1]) << 1
            nextCode[length] = code
            startIndex[length] = index
            index += countPerLength[length]
        }
        // `code` above starts at 0 for length 1 because countPerLength[0] is 0.

        orderedSymbols = [UInt16](repeating: 0, count: index)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let width = Int(length)
            orderedSymbols[startIndex[width]] = UInt16(symbol)
            startIndex[width] += 1

            let assigned = nextCode[width]
            nextCode[width] += 1
            if width <= Self.lookupBits {
                let spread = Self.lookupBits - width
                let first = assigned << spread
                let entry = UInt16(symbol) << 4 | UInt16(width)
                for slot in first..<(first + (1 << spread)) {
                    lookup[slot] = entry
                }
            }
        }
    }

    /// Decode one symbol.
    ///
    /// - Throws: ``RARError/corruptData`` when the next bits are not a code
    ///   of this alphabet, ``RARError/truncated`` when the code runs past the
    ///   end of the input.
    func decode(_ reader: inout MSBBitReader) throws -> Int {
        let entry = lookup[Int(reader.peek(Self.lookupBits))]
        if entry != 0 {
            try reader.skip(Int(entry & 0x0F))
            return Int(entry >> 4)
        }
        let window = reader.peek(Self.maxLength)
        var code = 0
        var firstCode = 0
        var index = 0
        for length in 1...Self.maxLength {
            code |= Int((window >> UInt32(Self.maxLength - length)) & 1)
            let count = countPerLength[length]
            if code - firstCode < count {
                try reader.skip(length)
                return Int(orderedSymbols[index + code - firstCode])
            }
            index += count
            firstCode = (firstCode + count) << 1
            code <<= 1
        }
        throw RARError.corruptData
    }
}
