/// Sequential little-endian reader over the bytes of one block header.
///
/// The header has already been copied out of the archive, so every read is
/// checked against the header's own length: running past it means the
/// header's fields contradict its `HEAD_SIZE`, which is reported as
/// ``RARError/malformedHeader``.
struct FieldReader {
    private let bytes: [UInt8]
    /// Index of the next unread byte.
    private(set) var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    /// Number of bytes not yet read.
    var remaining: Int { bytes.count - position }

    private mutating func claim(_ count: Int) throws -> Int {
        guard count >= 0, count <= remaining else { throw RARError.malformedHeader }
        let start = position
        position += count
        return start
    }

    mutating func uint8() throws -> UInt8 {
        bytes[try claim(1)]
    }

    mutating func uint16() throws -> UInt16 {
        let at = try claim(2)
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    mutating func uint32() throws -> UInt32 {
        let at = try claim(4)
        return UInt32(bytes[at])
            | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16
            | UInt32(bytes[at + 3]) << 24
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        let at = try claim(count)
        return Array(bytes[at..<(at + count)])
    }

    mutating func skip(_ count: Int) throws {
        _ = try claim(count)
    }
}
