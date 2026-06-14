import Foundation

/// Walks the block stream of a RAR3 archive and yields `RAREntry` values for
/// every `FILE_HEAD` block encountered, skipping subblock and auxiliary
/// block types and terminating cleanly on `ENDARC_HEAD`.
///
/// Construction parameters:
/// - `data`: the full archive bytes.
/// - `bodyOffset`: byte offset immediately past the 7-byte RAR3 signature.
/// - `mainHeader`: parsed `RAR3MainHeader` (used to detect unsupported
///   archive-level features like encryption).
enum RAR3EntryIterator {

    static func entries(in data: Data, bodyOffset: Int) throws -> [RAREntry] {
        // Parse MAIN_HEAD first.
        guard bodyOffset + 7 <= data.endIndex else { throw RARError.truncated }
        let main = try RAR3MainHeader.parse(data, at: bodyOffset)
        if main.isEncrypted {
            throw RARError.unsupportedFeature("archive header encryption")
        }
        if main.isVolume {
            throw RARError.unsupportedFeature("multi-volume archives")
        }

        var entries: [RAREntry] = []
        var cursor = main.blockOffset + main.headerSize

        // Walk blocks until ENDARC_HEAD or we run out of bytes. Defensive
        // ceiling: bail if we ever step past data.endIndex.
        while cursor + 7 <= data.endIndex {
            // Peek the common 7-byte header to learn the block type.
            var reader = ByteReader(data, cursor: cursor)
            _ = try reader.readUInt16LE()  // HEAD_CRC
            let typeByte = try reader.readUInt8()
            let rawFlags = try reader.readUInt16LE()
            let headSize = Int(try reader.readUInt16LE())
            if headSize < 7 { throw RARError.truncated }

            // ADD_SIZE (4 bytes) is present iff the LONG_BLOCK flag is set.
            var addSize: UInt64 = 0
            if (rawFlags & RAR3LongBlockFlag) != 0 {
                addSize = UInt64(try reader.readUInt32LE())
            }

            let nextBlock = cursor + headSize + Int(addSize)

            if let type = RAR3BlockType(rawValue: typeByte) {
                switch type {
                case .endArc:
                    return entries
                case .file:
                    let fh = try RAR3FileHeader.parse(data, at: cursor)
                    let entry = RAREntry(
                        name: fh.fileName,
                        unpackedSize: fh.unpackedSize,
                        packedSize: fh.packedSize,
                        compressionMethod: fh.method,
                        unpackVersion: fh.unpackVersion,
                        crc32: fh.crc32,
                        hostOS: fh.hostOS,
                        attributes: fh.attributes,
                        modificationDate: Self.decodeDosDate(fh.dosDateTime),
                        isDirectory: fh.isDirectory,
                        isEncrypted: fh.isEncrypted,
                        isSolid: fh.isSolid,
                        dataOffset: UInt64(fh.packedDataOffset)
                    )
                    entries.append(entry)
                case .main:
                    // Should not appear a second time — but if it does, skip.
                    break
                case .mark, .comment, .av, .sub, .protect, .sign, .newSub:
                    // Auxiliary block types. Skip — they don't represent
                    // user-visible file entries in the SwiftRAR enumeration.
                    break
                }
            } else {
                // Unknown block type. The RAR3 spec allows unknown blocks to
                // be skipped using the same headSize + addSize advancement
                // we already computed.
            }

            // Guard against zero-advance loops (corrupted archive with
            // headSize 0 and no addSize would otherwise spin forever).
            if nextBlock <= cursor {
                throw RARError.truncated
            }
            cursor = nextBlock
        }

        return entries
    }

    /// Decode a DOS-formatted timestamp (year offset from 1980) into a
    /// `Date`. Returns `nil` for the all-zero "no time recorded" value.
    private static func decodeDosDate(_ packed: UInt32) -> Date? {
        if packed == 0 { return nil }
        let second = Int((packed & 0x1F) * 2)
        let minute = Int((packed >> 5) & 0x3F)
        let hour   = Int((packed >> 11) & 0x1F)
        let day    = Int((packed >> 16) & 0x1F)
        let month  = Int((packed >> 21) & 0x0F)
        let year   = Int((packed >> 25) & 0x7F) + 1980

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
