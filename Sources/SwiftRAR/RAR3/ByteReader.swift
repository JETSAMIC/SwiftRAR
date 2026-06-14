import Foundation

/// Bounds-checked little-endian reader over a `Data` slice. RAR3 headers are
/// densely packed little-endian fields; this helper keeps the call sites
/// readable while still throwing `RARError.truncated` on any out-of-range
/// access.
///
/// `ByteReader` operates on an underlying `Data` value plus a cursor and a
/// hard end-index. Methods advance the cursor; `peek*` variants do not.
struct ByteReader {
    let data: Data
    private(set) var cursor: Int
    let limit: Int

    init(_ data: Data, cursor: Int = 0, limit: Int? = nil) {
        self.data = data
        self.cursor = cursor
        self.limit = limit ?? data.count
    }

    var remaining: Int { limit - cursor }
    var isAtEnd: Bool { cursor >= limit }

    mutating func readUInt8() throws -> UInt8 {
        guard cursor + 1 <= limit else { throw RARError.truncated }
        let byte = data[data.startIndex + cursor]
        cursor += 1
        return byte
    }

    mutating func readUInt16LE() throws -> UInt16 {
        guard cursor + 2 <= limit else { throw RARError.truncated }
        let lo = UInt16(data[data.startIndex + cursor])
        let hi = UInt16(data[data.startIndex + cursor + 1])
        cursor += 2
        return (hi << 8) | lo
    }

    mutating func readUInt32LE() throws -> UInt32 {
        guard cursor + 4 <= limit else { throw RARError.truncated }
        let base = data.startIndex + cursor
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        cursor += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, cursor + count <= limit else { throw RARError.truncated }
        let start = data.startIndex + cursor
        let slice = data.subdata(in: start..<(start + count))
        cursor += count
        return slice
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, cursor + count <= limit else { throw RARError.truncated }
        cursor += count
    }

    func peekUInt8(at offset: Int) throws -> UInt8 {
        guard cursor + offset + 1 <= limit else { throw RARError.truncated }
        return data[data.startIndex + cursor + offset]
    }
}
