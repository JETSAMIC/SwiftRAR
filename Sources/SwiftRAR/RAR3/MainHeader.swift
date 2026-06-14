import Foundation

/// RAR3 (classic) block-header type byte values. The values are the same
/// constants used by every public RAR3 spec since the original technote
/// shipped with WinRAR ≤4.x.
enum RAR3BlockType: UInt8 {
    case mark    = 0x72  // the signature itself, never seen mid-stream
    case main    = 0x73
    case file    = 0x74
    case comment = 0x75
    case av      = 0x76
    case sub     = 0x77
    case protect = 0x78
    case sign    = 0x79
    case newSub  = 0x7A
    case endArc  = 0x7B
}

/// Common header flag: when set, the 7-byte common header is followed by a
/// 4-byte `ADD_SIZE` field describing the length of data that follows the
/// header block (used by file and subblock headers).
let RAR3LongBlockFlag: UInt16 = 0x8000

/// MAIN_HEAD (0x73) flag bits. Only those we either react to or surface are
/// named; the unused-but-documented values are kept as comments for future
/// reference.
struct RAR3MainFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let volume        = RAR3MainFlags(rawValue: 0x0001)
    static let comment       = RAR3MainFlags(rawValue: 0x0002)
    static let lock          = RAR3MainFlags(rawValue: 0x0004)
    static let solid         = RAR3MainFlags(rawValue: 0x0008)
    static let newNumbering  = RAR3MainFlags(rawValue: 0x0010)
    static let av            = RAR3MainFlags(rawValue: 0x0020)
    static let `protect`     = RAR3MainFlags(rawValue: 0x0040)
    static let password      = RAR3MainFlags(rawValue: 0x0080)
    static let firstVolume   = RAR3MainFlags(rawValue: 0x0100)
    static let encryptVer    = RAR3MainFlags(rawValue: 0x0200)
}

/// Parsed representation of a RAR3 MAIN_HEAD block.
///
/// Only the bits SwiftRAR actually cares about are surfaced; the rest of the
/// header is consumed and skipped. `headerSize` is the total size of the
/// block header including the common 7-byte prefix — the next block begins
/// at `blockOffset + headerSize`.
struct RAR3MainHeader: Sendable {
    /// Offset within the archive `Data` where this header's common prefix
    /// begins.
    let blockOffset: Int
    /// Total size of the entire MAIN_HEAD block (common header + extension).
    let headerSize: Int
    /// Decoded flags.
    let flags: RAR3MainFlags

    /// Convenience accessors for the flags the parser surfaces to callers.
    var isVolume: Bool      { flags.contains(.volume) }
    var isSolid: Bool       { flags.contains(.solid) }
    var isEncrypted: Bool   { flags.contains(.password) }

    /// Decode the MAIN_HEAD starting at `blockOffset` within `data`. The
    /// caller is expected to have already verified that the byte at
    /// `blockOffset + 2` is `0x73`.
    static func parse(_ data: Data, at blockOffset: Int) throws -> RAR3MainHeader {
        // Common 7-byte header: HEAD_CRC(2), HEAD_TYPE(1), HEAD_FLAGS(2), HEAD_SIZE(2).
        var reader = ByteReader(data, cursor: blockOffset)
        _ = try reader.readUInt16LE()  // HEAD_CRC — verification is optional, deferred.
        let type = try reader.readUInt8()
        guard type == RAR3BlockType.main.rawValue else {
            throw RARError.unsupportedFeature("expected MAIN_HEAD (0x73), got 0x\(String(type, radix: 16))")
        }
        let rawFlags = try reader.readUInt16LE()
        let headSize = try reader.readUInt16LE()
        let flags = RAR3MainFlags(rawValue: rawFlags)

        // Sanity: the header size must at least cover the bytes we've read
        // plus the documented main-header extension (2-byte HighPosAV + 4-byte
        // PosAV = 6 bytes).
        if headSize < 13 {
            throw RARError.truncated
        }
        if blockOffset + Int(headSize) > data.endIndex {
            throw RARError.truncated
        }

        return RAR3MainHeader(
            blockOffset: blockOffset,
            headerSize: Int(headSize),
            flags: flags
        )
    }
}
