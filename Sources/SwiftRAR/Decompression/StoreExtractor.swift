import Foundation

/// Extracts entries packed with the STORE method (compression method `0x30`
/// in RAR3, or method-bits = 0 in RAR5). STORE entries are byte-identical to
/// the unpacked file — extraction is a bounds-checked slice plus a CRC32
/// verification against the header-stored checksum.
enum StoreExtractor {

    /// Copy the packed payload of `entry` out of `archive` and verify the
    /// CRC32 stored in the entry header.
    ///
    /// - Throws: `RARError.entryOffsetOutOfRange` when the entry's offset or
    ///   size walks past the end of `archive` (i.e. the caller is asking
    ///   about a different `Data` than the one the entry came from), or
    ///   `RARError.dataCRCMismatch` if the bytes don't match the expected
    ///   CRC.
    static func extract(_ entry: RAREntry, from archive: Data) throws -> Data {
        // Sanity: the entry must report STORE method.
        guard entry.compressionMethod == 0x30 else {
            throw RARError.unsupportedCompression(method: entry.compressionMethod)
        }

        // STORE entries have packedSize == unpackedSize.
        // Honour the header-stored packedSize for the bounds check.
        let start = Int(entry.dataOffset)
        let length = Int(entry.packedSize)
        guard start >= 0,
              length >= 0,
              start <= archive.count,
              start + length <= archive.count else {
            throw RARError.entryOffsetOutOfRange
        }

        let payload = archive.subdata(
            in: (archive.startIndex + start)..<(archive.startIndex + start + length)
        )

        // Verify CRC32 against the stored value. RAR3 stores zero CRC for
        // empty files; skip the check in that case to avoid false positives
        // on the trivial input.
        if entry.unpackedSize > 0 {
            if CRC32.compute(payload) != entry.crc32 {
                throw RARError.dataCRCMismatch
            }
        }
        return payload
    }
}
