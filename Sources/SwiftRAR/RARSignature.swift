import Foundation

/// Distinguishes the two major eras of the RAR container format.
///
/// The two formats share an identical 6-byte prefix (`"Rar!\x1A\x07"`) but
/// diverge in the trailing version bytes and in the entire structure of the
/// blocks that follow. Only ``classic`` archives can be listed and
/// extracted; ``rar5`` is detected so callers can route it elsewhere.
public enum RARFormat: Equatable, Sendable {
    /// RAR 1.5 through 4.x. Signature is 7 bytes (`Rar!\x1A\x07\x00`).
    /// Uses the classic block-header scheme (HEAD_CRC / HEAD_TYPE /
    /// HEAD_FLAGS / HEAD_SIZE).
    case classic

    /// RAR 5.0 and newer. Signature is 8 bytes (`Rar!\x1A\x07\x01\x00`).
    /// Uses vint-encoded headers. Not parsed by SwiftRAR.
    case rar5
}

/// Detector for RAR archive signatures, including self-extracting (SFX)
/// archives that prepend an executable stub to the actual RAR data.
///
/// The RAR 1.4 signature (`RE~^`) is not recognised.
public enum RARSignature {

    /// 7-byte signature for RAR 1.5-4.x: `"Rar!" 0x1A 0x07 0x00`.
    public static let classicBytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]

    /// 8-byte signature for RAR 5.0+: `"Rar!" 0x1A 0x07 0x01 0x00`.
    public static let rar5Bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    /// Largest self-extractor stub, in bytes, scanned past when looking for a
    /// signature (1 MiB, the limit RAR itself documents for RAR 5.0 SFX
    /// modules and a common convention for older ones).
    public static let sfxScanLimit = 1 << 20  // 1 MiB

    /// The result of a successful signature detection.
    public struct Detection: Equatable, Sendable {
        /// Which format era was detected.
        public let format: RARFormat
        /// Offset within the input `Data` where the signature begins. For a
        /// plain RAR archive this is `0`; for an SFX archive it is the offset
        /// past the executable stub.
        public let signatureOffset: Int
        /// Offset within the input `Data` where the first block header begins
        /// (i.e. `signatureOffset + signature.count`).
        public let bodyOffset: Int
    }

    /// Locate a RAR signature in `data`, scanning the first
    /// ``sfxScanLimit`` bytes to accommodate self-extracting archives.
    ///
    /// The first candidate wins; no blocks are parsed.
    ///
    /// - Parameter data: Candidate archive bytes. Offsets in the result are
    ///   relative to `data.startIndex`.
    /// - Returns: The detected format and offsets, or `nil` if no recognised
    ///   signature is found in the scan window.
    public static func detect(_ data: Data) -> Detection? {
        let limit = min(data.count, sfxScanLimit + rar5Bytes.count)
        guard limit >= classicBytes.count else { return nil }

        // Linear scan over the prefix. RAR signatures are rare enough that a
        // naive byte-by-byte check is fine; an SFX stub is typically a
        // PE/Mach-O/ELF image of a few hundred KB.
        var index = data.startIndex
        let scanEnd = data.startIndex + limit
        while index < scanEnd {
            if data[index] == 0x52,  // 'R'
               index + classicBytes.count <= data.endIndex,
               matchesPrefix(data, at: index, prefix: classicBytes[0..<6]) {
                // First 6 bytes match. Distinguish classic vs RAR5 by the next
                // 1-2 bytes.
                let versionOffset = index + 6
                if versionOffset >= data.endIndex { return nil }
                let v = data[versionOffset]
                if v == 0x00 {
                    let sigOffset = index - data.startIndex
                    return Detection(
                        format: .classic,
                        signatureOffset: sigOffset,
                        bodyOffset: sigOffset + classicBytes.count
                    )
                } else if v == 0x01 {
                    // Need the trailing 0x00 to call it RAR5.
                    let trailerOffset = index + 7
                    guard trailerOffset < data.endIndex,
                          data[trailerOffset] == 0x00 else {
                        // Looks like a near-miss; keep scanning past this
                        // candidate.
                        index = data.index(after: index)
                        continue
                    }
                    let sigOffset = index - data.startIndex
                    return Detection(
                        format: .rar5,
                        signatureOffset: sigOffset,
                        bodyOffset: sigOffset + rar5Bytes.count
                    )
                }
                // Some other version byte — not a signature we recognise; keep
                // looking in case an SFX stub coincidentally contained "Rar!".
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func matchesPrefix(_ data: Data, at offset: Data.Index, prefix: ArraySlice<UInt8>) -> Bool {
        var d = offset
        for byte in prefix {
            if d >= data.endIndex || data[d] != byte { return false }
            d = data.index(after: d)
        }
        return true
    }
}
