import Foundation

/// Walks the block sequence of a RAR 1.5–4.x archive (Reference §3.3.1) and
/// collects its file entries.
enum ClassicArchiveReader {

    /// Block type codes (Reference §3.3).
    private enum BlockType {
        static let main: UInt8 = 0x73
        static let file: UInt8 = 0x74
        static let service: UInt8 = 0x7A
        static let end: UInt8 = 0x7B
    }

    /// MAIN_HEAD flag bits used by the reader (Reference §3.5).
    private enum MainFlag {
        static let volume: UInt16 = 0x0001
        static let embeddedComment: UInt16 = 0x0002
        static let encryptedHeaders: UInt16 = 0x0080
    }

    private static let longBlock: UInt16 = 0x8000
    private static let mainHeaderSize = 13

    /// One block's common header plus a copy of its header bytes.
    private struct Block {
        let offset: Int
        let type: UInt8
        let flags: UInt16
        let storedCRC: UInt16
        let header: [UInt8]

        var size: Int { header.count }

        /// CRC16 over `header[2..<end]` (Reference §6.2).
        func crcMatches(through end: Int) -> Bool {
            guard end >= 2, end <= header.count else { return false }
            return UInt16(truncatingIfNeeded: CRC32.compute(header[2..<end])) == storedCRC
        }
    }

    /// List every FILE_HEAD entry of the archive.
    ///
    /// - Parameters:
    ///   - data: The whole input; offsets are relative to `data.startIndex`.
    ///   - bodyOffset: Offset of the first block (just past the marker).
    static func entries(in data: Data, bodyOffset: Int) throws -> [RAREntry] {
        let length = data.count
        var position = bodyOffset

        let main = try readBlock(data, at: position)
        guard main.type == BlockType.main, main.size >= mainHeaderSize else {
            throw RARError.malformedHeader
        }
        // An old-style embedded comment has its own CRC, so the main CRC
        // then covers only the fixed 13 bytes.
        let mainSpan = main.flags & MainFlag.embeddedComment != 0 ? mainHeaderSize : main.size
        guard main.crcMatches(through: mainSpan) else { throw RARError.headerCRCMismatch }
        if main.flags & MainFlag.encryptedHeaders != 0 {
            throw RARError.unsupportedFeature(.encryptedHeaders)
        }
        if main.flags & MainFlag.volume != 0 {
            throw RARError.unsupportedFeature(.multiVolume)
        }
        position = try advance(past: main, payload: try genericPayload(of: main), limit: length)

        var entries: [RAREntry] = []
        while position < length {
            let block = try readBlock(data, at: position)
            switch block.type {
            case BlockType.file, BlockType.service:
                let file = try parseFileBlock(block)
                let dataOffset = block.offset + block.size
                position = try advance(past: block, payload: file.packedSize, limit: length)
                if block.type == BlockType.file {
                    if file.isSplit {
                        throw RARError.unsupportedFeature(.multiVolume)
                    }
                    entries.append(makeEntry(file, dataOffset: dataOffset))
                }
            case BlockType.end:
                guard block.crcMatches(through: block.size) else { throw RARError.headerCRCMismatch }
                return entries
            default:
                // Legacy (0x75–0x79) and unknown blocks: skipped by length.
                // Their CRC coverage is not uniformly defined, so it is not
                // checked; their contents are never used.
                position = try advance(past: block, payload: try genericPayload(of: block), limit: length)
            }
        }
        return entries
    }

    /// Read the 7-byte common header at `offset` and copy HEAD_SIZE bytes.
    private static func readBlock(_ data: Data, at offset: Int) throws -> Block {
        guard data.count - offset >= 7 else { throw RARError.truncated }
        let base = data.startIndex + offset
        let storedCRC = UInt16(data[base]) | UInt16(data[base + 1]) << 8
        let type = data[base + 2]
        let flags = UInt16(data[base + 3]) | UInt16(data[base + 4]) << 8
        let size = Int(UInt16(data[base + 5]) | UInt16(data[base + 6]) << 8)
        guard size >= 7 else { throw RARError.malformedHeader }
        guard size <= data.count - offset else { throw RARError.truncated }
        let header = [UInt8](data[base..<(base + size)])
        return Block(offset: offset, type: type, flags: flags, storedCRC: storedCRC, header: header)
    }

    /// Payload length of a block that is not FILE_HEAD/NEWSUB_HEAD: ADD_SIZE
    /// when LONG_BLOCK is set, otherwise none.
    private static func genericPayload(of block: Block) throws -> UInt64 {
        guard block.flags & longBlock != 0 else { return 0 }
        var reader = FieldReader(block.header, position: 7)
        return UInt64(try reader.uint32())
    }

    /// Offset of the block after `block` and its payload, checking that the
    /// payload lies inside the input.
    private static func advance(past block: Block, payload: UInt64, limit: Int) throws -> Int {
        let available = UInt64(limit - block.offset - block.size)
        guard payload <= available else { throw RARError.truncated }
        return block.offset + block.size + Int(payload)
    }

    /// Verify and parse a FILE_HEAD or NEWSUB_HEAD.
    private static func parseFileBlock(_ block: Block) throws -> ClassicFileHeader {
        guard block.size >= ClassicFileHeader.fixedSize else { throw RARError.malformedHeader }
        if block.crcMatches(through: block.size) {
            return try ClassicFileHeader(header: block.header, flags: block.flags)
        }
        // RAR ≤ 2.x file comments sit after the name with their own CRC;
        // the header CRC then ends at the name.
        if block.flags & ClassicFileHeader.Flag.embeddedComment != 0 {
            let file = try ClassicFileHeader(header: block.header, flags: block.flags)
            if block.crcMatches(through: file.nameEnd) {
                return file
            }
        }
        throw RARError.headerCRCMismatch
    }

    private static func makeEntry(_ file: ClassicFileHeader, dataOffset: Int) -> RAREntry {
        var modified = DOSTimestamp.date(file.dosTime)
        if let ext = file.extendedTime, ext.hasModification {
            modified = DOSTimestamp.date(
                file.dosTime,
                extraSecond: ext.modificationExtraSecond,
                hundredNanoseconds: ext.modificationFraction
            )
        }
        return RAREntry(
            name: ClassicFileName.decode(
                file.nameField,
                hasUnicode: file.flags & ClassicFileHeader.Flag.unicodeName != 0,
                hostOS: file.hostOS
            ),
            unpackedSize: file.unpackedSize,
            packedSize: file.packedSize,
            compressionMethod: file.method,
            unpackVersion: file.unpackVersion,
            crc32: file.fileCRC,
            hostOS: file.hostOS,
            attributes: file.attributes,
            modificationDate: modified,
            isDirectory: file.isDirectory,
            isEncrypted: file.isEncrypted,
            isSolid: file.isSolid,
            dataOffset: UInt64(dataOffset)
        )
    }
}
