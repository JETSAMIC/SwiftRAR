import Foundation

/// Public entry point for inspecting and extracting RAR archives.
///
/// `RARArchive` is stateless: it exposes static methods that operate on an
/// in-memory `Data` value. ``entries(_:)`` walks the archive's block stream
/// and returns metadata for every file and directory, and
/// ``extract(entry:from:)`` returns (and CRC-verifies) one entry's bytes.
///
/// ### Supported input
///
/// - **RAR 1.5–4.x** archives (signature `Rar!\x1A\x07\x00`), including
///   self-extracting archives with a stub of up to 1 MiB: full listing.
/// - Extraction of **stored** entries (method `0x30`) of any version, and of
///   **compressed** entries (methods `0x31`–`0x35`) written with the RAR 2.9
///   algorithm (`UNP_VER` 29 or 36 — RAR/WinRAR 3.x and 4.x).
///
/// ### Rejected with ``RARError/unsupportedFeature(_:)``
///
/// RAR 5.0+ archives, multi-volume archives, archives with encrypted
/// headers, and — at extraction time — encrypted entries, solid
/// continuation entries, RAR 1.5/2.0 compression, PPMd blocks and RAR VM
/// filters. See ``RARFeature``.
///
/// ### Safety
///
/// All input is treated as untrusted: every header is bounds-checked, the
/// `HEAD_CRC` of every main, file, service and end block is verified,
/// decompression output is capped at the declared size, and
/// extracted data is CRC-32 verified. Entry names are *not* sanitised —
/// use ``RAREntry/sanitizedPath`` before touching the file system.
public enum RARArchive {

    /// Enumerate every file and directory entry in `data`.
    ///
    /// Auxiliary blocks (comments, recovery records, authenticity records,
    /// service headers) are skipped.
    ///
    /// - Parameter data: The complete archive. A `Data` slice is accepted;
    ///   offsets are relative to its `startIndex`.
    /// - Returns: The entries in archive order.
    /// - Throws: ``RARError/notRAR`` when no signature is found;
    ///   ``RARError/unsupportedFeature(_:)`` for RAR 5.0, multi-volume and
    ///   header-encrypted archives; ``RARError/truncated``,
    ///   ``RARError/malformedHeader`` or ``RARError/headerCRCMismatch`` for
    ///   damaged archives.
    public static func entries(_ data: Data) throws -> [RAREntry] {
        guard let detection = RARSignature.detect(data) else {
            throw RARError.notRAR
        }
        switch detection.format {
        case .classic:
            return try ClassicArchiveReader.entries(in: data, bodyOffset: detection.bodyOffset)
        case .rar5:
            throw RARError.unsupportedFeature(.rar5Archive)
        }
    }

    /// Extract the unpacked bytes of one entry.
    ///
    /// Directories return empty data. The result is always exactly
    /// ``RAREntry/unpackedSize`` bytes long and matches ``RAREntry/crc32``.
    ///
    /// The whole entry is produced in memory; the declared unpacked size is
    /// archive-controlled, so check ``RAREntry/unpackedSize`` against your
    /// own limit before calling this on untrusted input.
    ///
    /// - Parameters:
    ///   - entry: An entry returned by ``entries(_:)``.
    ///   - data: The same `Data` value `entry` was enumerated from.
    /// - Returns: The entry's contents.
    /// - Throws: ``RARError/unsupportedFeature(_:)`` for encrypted or solid
    ///   entries, unsupported algorithm versions, PPMd and VM filters;
    ///   ``RARError/unsupportedCompression(method:)`` for unknown method
    ///   bytes; ``RARError/entryOffsetOutOfRange`` if `data` is not the
    ///   entry's archive; ``RARError/entryTooLarge`` if the size does not fit
    ///   in memory on this platform; ``RARError/corruptData``,
    ///   ``RARError/truncated`` or ``RARError/dataCRCMismatch`` for damaged
    ///   data.
    public static func extract(entry: RAREntry, from data: Data) throws -> Data {
        if entry.isDirectory {
            return Data()
        }
        if entry.isEncrypted {
            throw RARError.unsupportedFeature(.encryptedEntry)
        }
        if entry.isSolid {
            throw RARError.unsupportedFeature(.solidEntry)
        }

        guard let start = Int(exactly: entry.dataOffset),
              let length = Int(exactly: entry.packedSize),
              start <= data.count, length <= data.count - start else {
            throw RARError.entryOffsetOutOfRange
        }
        guard let unpackedSize = Int(exactly: entry.unpackedSize) else {
            throw RARError.entryTooLarge
        }
        let base = data.startIndex + start
        let packed = data[base..<(base + length)]

        let output: Data
        switch entry.compressionMethod {
        case 0x30:
            // Stored: the payload is the file. An unencrypted stored entry
            // always has equal packed and unpacked sizes.
            guard packed.count == unpackedSize else { throw RARError.corruptData }
            output = Data(packed)
        case 0x31...0x35:
            // The method byte is only the compression level; UNP_VER selects
            // the bitstream format (Reference §5.3).
            switch entry.unpackVersion {
            case 29, 36:
                output = try LZ29Decoder.decode(packed, outputSize: unpackedSize)
            default:
                throw RARError.unsupportedFeature(.compressionVersion(entry.unpackVersion))
            }
        default:
            throw RARError.unsupportedCompression(method: entry.compressionMethod)
        }

        if CRC32.compute(output) != entry.crc32 {
            throw RARError.dataCRCMismatch
        }
        return output
    }

    /// Whether `data` contains a RAR signature (classic or RAR 5.0) within
    /// the self-extractor scan window. No blocks are parsed.
    ///
    /// - Parameter data: Candidate archive bytes.
    /// - Returns: `true` when ``RARSignature/detect(_:)`` finds a signature.
    public static func isRARArchive(_ data: Data) -> Bool {
        RARSignature.detect(data) != nil
    }
}
