import Foundation

/// Errors thrown by SwiftRAR while inspecting or extracting a RAR archive.
///
/// Every failure path in the package surfaces one of these cases — malformed
/// or hostile input never traps the process. Cases fall into three groups:
///
/// - **Not / not-yet supported input**: ``notRAR``,
///   ``unsupportedCompression(method:)``, ``unsupportedFeature(_:)``.
/// - **Damaged input**: ``truncated``, ``malformedHeader``,
///   ``headerCRCMismatch``, ``corruptData``, ``dataCRCMismatch``.
/// - **Caller / platform limits**: ``entryOffsetOutOfRange``,
///   ``entryTooLarge``.
public enum RARError: Error, Equatable, Sendable {
    /// The provided data does not begin with (or contain within the SFX scan
    /// window) a recognised RAR 1.5+ signature.
    case notRAR

    /// The archive ended while the parser still expected more bytes for the
    /// current header, payload, or compressed stream.
    case truncated

    /// A block header is structurally invalid — for example a `HEAD_SIZE`
    /// smaller than the fixed fields it must contain, or a name length that
    /// overruns the header.
    case malformedHeader

    /// A RAR 1.5–4.x block header failed its `HEAD_CRC` check (the low 16
    /// bits of the CRC-32 of the header bytes that follow the field).
    case headerCRCMismatch

    /// An entry's extracted payload failed the CRC-32 recorded in its file
    /// header.
    case dataCRCMismatch

    /// The compressed stream is invalid (bad Huffman table, a match that
    /// reaches before the start of the file, a stream that ends before
    /// producing the declared unpacked size, …).
    case corruptData

    /// The entry uses a compression method byte this package does not know
    /// (anything outside `0x30`–`0x35`).
    case unsupportedCompression(method: UInt8)

    /// The archive or entry uses a feature SwiftRAR deliberately does not
    /// implement. See ``RARFeature`` for the list.
    case unsupportedFeature(RARFeature)

    /// The entry's payload range does not lie inside the `Data` passed to
    /// ``RARArchive/extract(entry:from:)`` — usually because the entry was
    /// enumerated from a different archive.
    case entryOffsetOutOfRange

    /// The entry's declared size cannot be represented in memory on this
    /// platform (for example a > 2 GiB entry on a 32-bit watchOS device).
    case entryTooLarge
}

/// A RAR feature that SwiftRAR recognises but does not implement.
///
/// Carried by ``RARError/unsupportedFeature(_:)`` so callers can decide how
/// to route the archive (for example, hand it to a full RAR implementation).
public enum RARFeature: Equatable, Sendable {
    /// The archive is in the RAR 5.0+ format (signature
    /// `Rar!\x1A\x07\x01\x00`). Only detection is implemented.
    case rar5Archive
    /// The archive is one volume of a multi-volume set (`MHD_VOLUME`).
    case multiVolume
    /// The archive's block headers are encrypted (`MHD_PASSWORD`); not even
    /// the entry list can be read without the password.
    case encryptedHeaders
    /// The entry's payload is encrypted (`LHD_PASSWORD`).
    case encryptedEntry
    /// The entry continues the dictionary of the previous entry in a solid
    /// archive (`LHD_SOLID`) and cannot be decoded on its own.
    case solidEntry
    /// The compressed stream contains a PPMd (PPMII variant H) block.
    case ppmd
    /// The compressed stream contains a RAR VM filter (E8/E8E9, delta, RGB,
    /// audio, Itanium or a custom program).
    case vmFilter
    /// The entry was compressed with an algorithm generation other than
    /// RAR 2.9 (`UNP_VER` 29 or 36) — RAR 1.5 (15) and RAR 2.0 (20/26) are
    /// not implemented. The associated value is the raw `UNP_VER` byte.
    case compressionVersion(UInt8)
}

extension RARFeature: CustomStringConvertible {
    /// A short human-readable name for the feature.
    public var description: String {
        switch self {
        case .rar5Archive: return "RAR 5.0 archive format"
        case .multiVolume: return "multi-volume archives"
        case .encryptedHeaders: return "encrypted archive headers"
        case .encryptedEntry: return "encrypted entries"
        case .solidEntry: return "solid-archive entries"
        case .ppmd: return "PPMd compression"
        case .vmFilter: return "RAR VM filters"
        case .compressionVersion(let version):
            return "compression algorithm version \(version / 10).\(version % 10)"
        }
    }
}

extension RARError: LocalizedError {
    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .notRAR:
            return "Data is not a RAR archive."
        case .truncated:
            return "RAR archive is truncated."
        case .malformedHeader:
            return "RAR archive contains a malformed block header."
        case .headerCRCMismatch:
            return "RAR header CRC mismatch."
        case .dataCRCMismatch:
            return "RAR entry data CRC mismatch."
        case .corruptData:
            return "RAR entry contains corrupt compressed data."
        case .unsupportedCompression(let method):
            return String(format: "RAR entry uses unknown compression method 0x%02X.", method)
        case .unsupportedFeature(let feature):
            return "RAR archive uses an unsupported feature: \(feature)."
        case .entryOffsetOutOfRange:
            return "RAR entry data offset is outside the provided archive data."
        case .entryTooLarge:
            return "RAR entry is too large to extract on this platform."
        }
    }
}
