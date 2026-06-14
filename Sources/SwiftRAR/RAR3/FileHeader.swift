import Foundation

/// FILE_HEAD (0x74) flag bits.
struct RAR3FileFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let splitBefore = RAR3FileFlags(rawValue: 0x0001)
    static let splitAfter  = RAR3FileFlags(rawValue: 0x0002)
    static let password    = RAR3FileFlags(rawValue: 0x0004)
    static let comment     = RAR3FileFlags(rawValue: 0x0008)
    static let solid       = RAR3FileFlags(rawValue: 0x0010)
    /// Indicates HIGH_PACK_SIZE / HIGH_UNP_SIZE present (>4 GB entries).
    static let large       = RAR3FileFlags(rawValue: 0x0100)
    /// Filename stored as combined CP437 + UTF-16 little-endian.
    static let unicode     = RAR3FileFlags(rawValue: 0x0200)
    static let salt        = RAR3FileFlags(rawValue: 0x0400)
    static let version     = RAR3FileFlags(rawValue: 0x0800)
    static let extTime     = RAR3FileFlags(rawValue: 0x1000)
    static let extFlags    = RAR3FileFlags(rawValue: 0x2000)

    /// Bits 5-7 encode the dictionary / window size. The value `0xE0` is the
    /// special "this is a directory" marker.
    static let directoryMarker: UInt16 = 0x00E0

    var isDirectory: Bool {
        (rawValue & Self.directoryMarker) == Self.directoryMarker
    }
}

/// Parsed representation of a RAR3 FILE_HEAD block.
///
/// `packedDataOffset` points at the first byte of the entry's compressed
/// payload within the archive `Data`. The next block header begins at
/// `packedDataOffset + packedSize`.
struct RAR3FileHeader: Sendable {
    let blockOffset: Int
    let headerSize: Int
    let flags: RAR3FileFlags

    let packedSize: UInt64
    let unpackedSize: UInt64
    let hostOS: UInt8
    let crc32: UInt32
    let dosDateTime: UInt32
    let unpackVersion: UInt8
    let method: UInt8
    let attributes: UInt32

    let fileName: String

    /// Offset of the entry's packed bytes within the source archive `Data`.
    let packedDataOffset: Int

    var isDirectory: Bool { flags.isDirectory }
    var isEncrypted: Bool { flags.contains(.password) }
    var isSolid: Bool     { flags.contains(.solid) }
    var isStored: Bool    { method == 0x30 }

    /// Decode the FILE_HEAD starting at `blockOffset` within `data`. The
    /// caller has already verified that the byte at `blockOffset + 2` is
    /// `0x74`.
    static func parse(_ data: Data, at blockOffset: Int) throws -> RAR3FileHeader {
        // Common 7-byte header.
        var reader = ByteReader(data, cursor: blockOffset)
        _ = try reader.readUInt16LE()  // HEAD_CRC.
        let type = try reader.readUInt8()
        guard type == RAR3BlockType.file.rawValue else {
            throw RARError.unsupportedFeature("expected FILE_HEAD (0x74), got 0x\(String(type, radix: 16))")
        }
        let rawFlags = try reader.readUInt16LE()
        let headSize = try reader.readUInt16LE()
        let flags = RAR3FileFlags(rawValue: rawFlags)

        // FILE_HEAD always uses the "long block" form: HEAD_FLAGS has bit
        // 0x8000 set and the following 4-byte ADD_SIZE is the packed-data
        // length.
        let packedLow = UInt64(try reader.readUInt32LE())
        let unpackedLow = UInt64(try reader.readUInt32LE())
        let hostOS = try reader.readUInt8()
        let crc = try reader.readUInt32LE()
        let dosTime = try reader.readUInt32LE()
        let unpVer = try reader.readUInt8()
        let method = try reader.readUInt8()
        let nameSize = Int(try reader.readUInt16LE())
        let attr = try reader.readUInt32LE()

        var packedSize = packedLow
        var unpackedSize = unpackedLow
        if flags.contains(.large) {
            let hiPacked = UInt64(try reader.readUInt32LE())
            let hiUnpacked = UInt64(try reader.readUInt32LE())
            packedSize |= hiPacked << 32
            unpackedSize |= hiUnpacked << 32
        }

        guard nameSize >= 0, reader.cursor + nameSize <= blockOffset + Int(headSize) else {
            throw RARError.truncated
        }
        let nameBytes = try reader.readBytes(nameSize)
        let fileName = decodeFileName(
            nameBytes,
            usesUnicodeEncoding: flags.contains(.unicode)
        )

        // Header size bounds-check the whole block: the common prefix plus
        // every variable-length tail (NAME, SALT, ExtTime…) must all fit
        // inside `headSize` bytes from blockOffset.
        let headerEnd = blockOffset + Int(headSize)
        if headerEnd > data.endIndex {
            throw RARError.truncated
        }
        // Packed data follows the header block.
        let packedOffset = headerEnd
        if packedOffset > data.endIndex {
            throw RARError.truncated
        }
        if UInt64(data.endIndex - packedOffset) < packedSize {
            throw RARError.truncated
        }

        return RAR3FileHeader(
            blockOffset: blockOffset,
            headerSize: Int(headSize),
            flags: flags,
            packedSize: packedSize,
            unpackedSize: unpackedSize,
            hostOS: hostOS,
            crc32: crc,
            dosDateTime: dosTime,
            unpackVersion: unpVer,
            method: method,
            attributes: attr,
            fileName: fileName,
            packedDataOffset: packedOffset
        )
    }

    /// Decode a FILE_HEAD `FILE_NAME` field.
    ///
    /// When the `LHD_UNICODE` flag is set, RAR3 stores the name as the OEM
    /// (CP437) bytes followed by a `0x00` separator and a compressed UTF-16
    /// encoding of the same name. The encoding for that UTF-16 portion uses
    /// a small command-byte language documented in the RAR3 technote. For
    /// SwiftRAR's read-only enumeration use case the CP437 (or ASCII)
    /// portion is sufficient — fully decoding the UTF-16 stream is deferred
    /// alongside the rest of the compressed-method work. ASCII filenames
    /// (overwhelmingly common in 16colors-era archives) round-trip cleanly.
    private static func decodeFileName(_ raw: Data, usesUnicodeEncoding: Bool) -> String {
        // The "OEM" portion is everything up to the first NUL when unicode
        // mode is on; otherwise it's the full buffer.
        let oemPortion: Data
        if usesUnicodeEncoding, let nul = raw.firstIndex(of: 0x00) {
            oemPortion = raw.subdata(in: raw.startIndex..<nul)
        } else {
            oemPortion = raw
        }
        // Most archives we'll encounter use plain ASCII for filenames. Decode
        // as ASCII-with-CP437-fallback by mapping bytes 0x80-0xFF to U+0080
        // through U+00FF (a Latin-1 passthrough). This is lossy for some
        // CP437 box-drawing characters but does not corrupt round-tripping
        // for the ASCII subset.
        var scalars = String.UnicodeScalarView()
        for byte in oemPortion {
            scalars.append(Unicode.Scalar(byte))
        }
        return String(scalars)
    }
}
