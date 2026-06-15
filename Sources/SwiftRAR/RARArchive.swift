import Foundation

/// Public entry point for inspecting and extracting RAR archives.
///
/// `RARArchive` is stateless — it exposes two static methods that operate on
/// `Data` values. `entries(_:)` walks the archive's block stream and returns
/// metadata for every user-visible file, while `extract(entry:from:)` copies
/// (and CRC-verifies) the bytes of a single STORE-method entry.
///
/// ### Supported formats
///
/// - **RAR 1.5 / 2.x / 3.x / 4.x** (classic block scheme): header parsing
///   and STORE extraction.
/// - **RAR 5.0+**: signature detection only in this release. Calling
///   `entries(_:)` on a RAR5 archive throws
///   `RARError.unsupportedFeature("RAR5 block parsing")`. RAR5 support is
///   tracked alongside the broader compressed-method deferral.
///
/// ### Compression methods
///
/// Only the STORE method (`0x30`) is implemented for extraction. Attempting
/// to extract a compressed entry throws `RARError.unsupportedCompression`.
/// See `RAR3LZSSDecoder.swift` for the rationale and the implementation
/// roadmap.
public enum RARArchive {

    /// Enumerate every user-visible file or directory entry in `data`.
    ///
    /// The returned `RAREntry` values carry metadata plus the offset of the
    /// entry's packed bytes within `data`. Calling `extract(entry:from:)`
    /// with the same `Data` value will produce the entry's payload.
    ///
    /// Auxiliary blocks (comments, AV records, recovery records, signature
    /// blocks, subblocks) are silently skipped — `entries` only returns
    /// blocks that represent files or directories.
    public static func entries(_ data: Data) throws -> [RAREntry] {
        guard let detection = RARSignature.detect(data) else {
            throw RARError.notRAR
        }
        switch detection.format {
        case .classic:
            return try RAR3EntryIterator.entries(in: data, bodyOffset: detection.bodyOffset)
        case .rar5:
            // RAR5 vint-based block parsing is deferred to the same follow-up
            // that introduces the RAR5 decompressors. For now we acknowledge
            // detection but refuse enumeration so callers can react with a
            // clear "unsupported archive" UX rather than getting back an
            // empty entry list.
            throw RARError.unsupportedFeature("RAR5 block parsing")
        }
    }

    /// Extract the unpacked bytes of a single entry from the archive it was
    /// enumerated from.
    ///
    /// Only STORE-method entries (`compressionMethod == 0x30`) are supported;
    /// every other method throws `RARError.unsupportedCompression`.
    /// Encrypted and solid entries throw `RARError.unsupportedFeature`.
    ///
    /// - Parameters:
    ///   - entry: An entry returned by `entries(_:)`.
    ///   - data: The same `Data` value `entry` was enumerated from. Passing a
    ///     different archive throws `RARError.entryOffsetOutOfRange`.
    public static func extract(entry: RAREntry, from data: Data) throws -> Data {
        if entry.isEncrypted {
            throw RARError.unsupportedFeature("encrypted entries")
        }
        if entry.isSolid {
            throw RARError.unsupportedFeature("solid-archive entries")
        }
        switch entry.compressionMethod {
        case 0x30:
            return try StoreExtractor.extract(entry, from: data)
        case 0x31, 0x32, 0x33, 0x34, 0x35:
            // RAR3 LZSS — all five "fastest..best" methods share the same
            // bitstream format; they differ only in encoder-side match-finder
            // heuristics. A single decoder serves the whole family.
            return try RAR3LZSSDecoder.decompress(entry, from: data)
        default:
            // Anything else — typically RAR5 method bits or an unknown future
            // method — bubbles up so the caller can surface a "please use
            // The Unarchiver" message instead of a parse error.
            throw RARError.unsupportedCompression(method: entry.compressionMethod)
        }
    }

    /// Convenience accessor for callers that just want to know whether a
    /// blob is a RAR archive without parsing its blocks.
    public static func isRARArchive(_ data: Data) -> Bool {
        RARSignature.detect(data) != nil
    }
}
