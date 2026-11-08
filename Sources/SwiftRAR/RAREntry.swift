import Foundation

/// Metadata for a single file or directory entry inside a RAR archive.
///
/// `RAREntry` is the unit returned by ``RARArchive/entries(_:)``. It carries
/// everything a caller needs to display the archive contents and to ask for
/// the entry's bytes via ``RARArchive/extract(entry:from:)``.
///
/// ``dataOffset`` and ``packedSize`` describe the location of the entry's
/// packed bytes within the original archive `Data`. They are valid only for
/// the exact `Data` value the entry was enumerated from.
///
/// > Important: ``name`` is untrusted archive content. It can be absolute,
/// > contain `..` components or a drive letter. Never append it to a
/// > destination directory directly — use ``sanitizedPath`` instead.
public struct RAREntry: Equatable, Sendable {
    /// The entry's path inside the archive, exactly as stored (after
    /// character decoding).
    ///
    /// Names are decoded from the Unicode form when the archive has one
    /// (`LHD_UNICODE`: UTF-8 or RAR's compact UTF-16), otherwise as UTF-8
    /// when valid and as IBM code page 437 when not. For archives created on
    /// MS-DOS, OS/2 or Windows the stored `\` separators are converted to
    /// `/`. No other normalisation is applied — see ``sanitizedPath``.
    public let name: String
    /// Size of the entry after decompression, in bytes.
    public let unpackedSize: UInt64
    /// Size of the entry's packed (compressed and/or encrypted) payload in
    /// the archive, in bytes.
    public let packedSize: UInt64
    /// The `METHOD` byte: `0x30` = store, `0x31`–`0x35` = fastest…best.
    ///
    /// The method is only the compression *level*; the algorithm is selected
    /// by ``unpackVersion``.
    public let compressionMethod: UInt8
    /// The `UNP_VER` byte: the RAR version needed to extract, times ten.
    /// `15` = RAR 1.5, `20`/`26` = RAR 2.0, `29`/`36` = RAR 2.9 (3.x/4.x).
    /// SwiftRAR decompresses only `29` and `36` (stored entries extract
    /// regardless).
    public let unpackVersion: UInt8
    /// CRC-32 of the *uncompressed* data, as stored in the file header.
    public let crc32: UInt32
    /// The `HOST_OS` byte: `0` MS-DOS, `1` OS/2, `2` Windows, `3` Unix,
    /// `4` Mac OS, `5` BeOS.
    public let hostOS: UInt8
    /// Host-specific attribute bits: a DOS/Windows attribute mask for hosts
    /// 0–2, a Unix `st_mode` for host 3.
    public let attributes: UInt32
    /// Last-modification time, or `nil` when the archive did not record a
    /// valid one.
    ///
    /// RAR stores MS-DOS wall-clock time without a time zone; SwiftRAR
    /// interprets the fields as UTC. When the header has an extended-time
    /// record (RAR ≥ 2.9) its sub-second precision is applied.
    public let modificationDate: Date?
    /// `true` when the entry is a directory rather than a file.
    public let isDirectory: Bool
    /// `true` when the entry's payload is encrypted. Such entries are listed
    /// but cannot be extracted (``RARFeature/encryptedEntry``).
    public let isEncrypted: Bool
    /// `true` when the entry continues the dictionary of the previous entry
    /// of a solid archive. Such entries are listed but cannot be extracted
    /// (``RARFeature/solidEntry``). The first entry of a solid archive is
    /// not marked and extracts normally.
    public let isSolid: Bool
    /// Byte offset of the entry's packed payload, counted from the start of
    /// the archive `Data` (its `startIndex`).
    public let dataOffset: UInt64

    /// `true` when the entry is a Unix symbolic link (host OS 3 with
    /// `S_IFLNK` in ``attributes``). Its payload is the link target, which is
    /// as untrusted as ``name``.
    public var isSymbolicLink: Bool {
        hostOS == 3 && (attributes & 0o170000) == 0o120000
    }

    /// ``name`` reduced to a relative path that is safe to resolve under an
    /// extraction directory, or `nil` when no safe form exists.
    ///
    /// Both `/` and `\` are treated as separators; empty and `.` components,
    /// leading separators (absolute and UNC paths) and a leading drive prefix
    /// such as `C:` are removed, and the components are re-joined with `/`.
    /// Returns `nil` if any component is `..` or the result is empty, so a
    /// hostile name can never escape the destination directory.
    public var sanitizedPath: String? {
        var components: [Substring] = []
        for component in name.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            var part = component
            if components.isEmpty, part.count >= 2,
               let first = part.first, first.isASCII, first.isLetter,
               part[part.index(after: part.startIndex)] == ":" {
                part = part.dropFirst(2)
            }
            if part.isEmpty || part == "." { continue }
            if part == ".." { return nil }
            components.append(part)
        }
        if components.isEmpty { return nil }
        return components.joined(separator: "/")
    }
}
