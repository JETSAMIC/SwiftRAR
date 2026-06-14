import Foundation

/// Metadata for a single file or directory entry inside a RAR archive.
///
/// `RAREntry` is the unit returned by `RARArchive.entries(_:)`. It carries
/// everything a caller needs to display the archive contents and to ask for
/// the entry's bytes via `RARArchive.extract(entry:from:)`.
///
/// `dataOffset` and `packedSize` together describe the location of the
/// entry's compressed bytes within the original archive `Data`. They are
/// valid only for the exact `Data` value the entry was enumerated from — the
/// `extract` API rejects mismatched offsets.
public struct RAREntry: Equatable, Sendable {
    /// Decoded file name (RAR3 entries use CP437/Latin-1 passthrough; RAR5
    /// entries use UTF-8 directly).
    public let name: String
    /// Logical file size after decompression.
    public let unpackedSize: UInt64
    /// On-disk size of the compressed payload.
    public let packedSize: UInt64
    /// RAR compression method byte. `0x30` = STORE; `0x31`-`0x35` are the
    /// compressed methods that SwiftRAR currently rejects in `extract`.
    public let compressionMethod: UInt8
    /// `UNP_VER` field from the originating archive. 15/20/26/29/36 for RAR3
    /// generations; SwiftRAR also surfaces a synthetic value for RAR5
    /// entries (see `RARArchive`).
    public let unpackVersion: UInt8
    /// CRC32 of the *uncompressed* data, as stored in the file header.
    public let crc32: UInt32
    /// `HOST_OS` byte from the RAR3 file header (RAR5 uses 0/1 here).
    public let hostOS: UInt8
    /// OS-specific attribute bits (typically a Windows attribute mask).
    public let attributes: UInt32
    /// File modification time, decoded from the on-disk DOS or Unix
    /// representation. `nil` when the source archive did not record one.
    public let modificationDate: Date?
    /// `true` when the entry is a directory placeholder rather than a file.
    public let isDirectory: Bool
    /// `true` when the entry's payload is encrypted (SwiftRAR cannot extract
    /// these — see `RARError.unsupportedFeature`).
    public let isEncrypted: Bool
    /// `true` when the entry depends on the decompressor's dictionary state
    /// inherited from preceding entries (solid mode — also unsupported in
    /// the initial release).
    public let isSolid: Bool
    /// Byte offset of the entry's packed payload within the source archive
    /// `Data`. Use with `packedSize` for `extract`.
    public let dataOffset: UInt64
}
