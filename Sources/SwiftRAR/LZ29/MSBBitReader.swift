/// Most-significant-bit-first reader over a compressed payload
/// (Reference §6.3.1).
///
/// Looking ahead past the end yields zero bits, so a prefix code whose last
/// symbol is shorter than the look-ahead window can still be decoded.
/// *Consuming* bits past the end throws ``RARError/truncated``.
struct MSBBitReader {
    private let bytes: [UInt8]
    /// Absolute index of the next unread bit.
    private(set) var bitOffset = 0
    /// Total number of bits in the input.
    let bitLength: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.bitLength = bytes.count * 8
    }

    /// Bits not yet consumed.
    var bitsRemaining: Int { bitLength - bitOffset }

    /// The next `count` bits (1…24) as an unsigned value, first bit most
    /// significant, without consuming them. Missing bits read as zero.
    func peek(_ count: Int) -> UInt32 {
        let byteIndex = bitOffset >> 3
        var window: UInt32 = 0
        if byteIndex + 4 <= bytes.count {
            window = UInt32(bytes[byteIndex]) << 24
                | UInt32(bytes[byteIndex + 1]) << 16
                | UInt32(bytes[byteIndex + 2]) << 8
                | UInt32(bytes[byteIndex + 3])
        } else {
            for k in 0..<4 {
                window <<= 8
                if byteIndex + k < bytes.count {
                    window |= UInt32(bytes[byteIndex + k])
                }
            }
        }
        // At most 7 leading bits are already used, leaving ≥ 25 valid bits.
        return (window << UInt32(bitOffset & 7)) >> UInt32(32 - count)
    }

    /// Consume `count` bits.
    mutating func skip(_ count: Int) throws {
        guard count <= bitsRemaining else {
            bitOffset = bitLength
            throw RARError.truncated
        }
        bitOffset += count
    }

    /// Consume and return the next `count` bits (0…24).
    mutating func read(_ count: Int) throws -> UInt32 {
        guard count > 0 else { return 0 }
        let value = peek(count)
        try skip(count)
        return value
    }

    /// Discard bits up to the next byte boundary.
    mutating func alignToByte() {
        bitOffset = min((bitOffset + 7) & ~7, bitLength)
    }
}
