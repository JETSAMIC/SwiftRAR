/// Constant tables of the RAR 2.9 bitstream (Reference §6.3.6, §6.3.7).
enum LZ29Tables {

    // MARK: Alphabet sizes, in transmission order

    static let mainSymbols = 299
    static let distanceSlotSymbols = 60
    static let lowDistanceSymbols = 17
    static let lengthSymbols = 28
    /// Code lengths sent per table set: 299 + 60 + 17 + 28.
    static let totalCodeLengths = mainSymbols + distanceSlotSymbols + lowDistanceSymbols + lengthSymbols
    /// Size of the pre-code alphabet used to send the code lengths.
    static let preCodeSymbols = 20

    // MARK: Lengths (codes 0…27)

    /// Length contribution of each length code; from code 8 on the step
    /// doubles every four codes.
    static let lengthBase: [Int] = {
        var bases: [Int] = []
        var value = 0
        for code in 0..<28 {
            bases.append(value)
            value += 1 << lengthExtraBits[code]
        }
        return bases
    }()

    /// Raw bits that follow each length code.
    static let lengthExtraBits: [Int] = (0..<28).map { $0 < 8 ? 0 : ($0 - 4) / 4 }

    // MARK: Distance slots (0…59)

    /// How many consecutive slots use 0, 1, 2, … 18 extra bits.
    private static let slotsPerExtraBitCount = [4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12]

    /// `(base, extraBits)` for each distance slot.
    static let distanceSlots: [(base: Int, extraBits: Int)] = {
        var slots: [(base: Int, extraBits: Int)] = []
        var base = 0
        for (extraBits, count) in slotsPerExtraBitCount.enumerated() {
            for _ in 0..<count {
                slots.append((base, extraBits))
                base += 1 << extraBits
            }
        }
        return slots
    }()

    /// Largest distance the slot table can express (4 MiB).
    static let maxDistance = 4 << 20

    // MARK: Short matches (symbols 263…270)

    static let shortBase = [0, 4, 8, 16, 32, 64, 128, 192]
    static let shortExtraBits = [2, 2, 3, 4, 5, 6, 6, 6]
}
