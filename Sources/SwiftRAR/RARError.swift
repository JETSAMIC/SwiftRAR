import Foundation

/// Errors thrown by SwiftRAR while inspecting or extracting a RAR archive.
public enum RARError: Error, Equatable, Sendable {
    /// The provided data does not begin with (or contain within the SFX scan
    /// window) a recognised RAR signature.
    case notRAR

    /// The signature is recognised but the format version is not handled by
    /// this package (e.g. a hypothetical future RAR6 or a corrupted signature
    /// byte).
    case unsupportedVersion

    /// The archive ended while the parser still expected more bytes for the
    /// current header or data region.
    case truncated

    /// A RAR3 block header failed its CRC16 check.
    case headerCRCMismatch

    /// A stored entry's payload failed the CRC32 verification recorded in its
    /// file header.
    case dataCRCMismatch

    /// The entry uses a compression method this package does not (yet)
    /// implement. STORE (0x30 in RAR3, method bits = 0 in RAR5) is the only
    /// fully supported method in the initial release.
    case unsupportedCompression(method: UInt8)

    /// A specific archive feature that SwiftRAR does not implement was
    /// encountered (e.g. encryption, multi-volume continuation, solid mode).
    case unsupportedFeature(String)

    /// The caller asked to extract an entry that did not originate from the
    /// same `Data` it was enumerated from (offset bounds invalid).
    case entryOffsetOutOfRange
}

extension RARError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRAR:
            return "Data is not a RAR archive."
        case .unsupportedVersion:
            return "RAR archive uses a format version SwiftRAR does not support."
        case .truncated:
            return "RAR archive is truncated."
        case .headerCRCMismatch:
            return "RAR header CRC mismatch."
        case .dataCRCMismatch:
            return "RAR entry data CRC mismatch."
        case .unsupportedCompression(let method):
            return String(
                format: "RAR entry uses unsupported compression method 0x%02X. " +
                "Only STORE (uncompressed) is implemented.",
                method
            )
        case .unsupportedFeature(let name):
            return "RAR archive uses unsupported feature: \(name)."
        case .entryOffsetOutOfRange:
            return "RAR entry data offset is outside the provided archive data."
        }
    }
}
