import Foundation

/// IEEE 802.3 CRC32 (reflected, polynomial `0xEDB88320`) used by RAR for
/// per-file payload checksums, and by RAR5 for header checksums.
///
/// This is the same CRC32 used by zlib, PNG, ZIP and gzip — it is included
/// here so SwiftRAR has zero non-Foundation dependencies.
public enum CRC32 {

    /// Initial / final XOR value applied to the running CRC.
    public static let initial: UInt32 = 0xFFFFFFFF

    /// Compute the CRC32 of an arbitrary byte buffer.
    public static func compute<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc = initial
        let table = Self.table
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ initial
    }

    /// Convenience overload for `Data` that uses unsafe pointer iteration to
    /// avoid `Sequence`-iterator overhead on large payloads.
    public static func compute(_ data: Data) -> UInt32 {
        var crc = initial
        let table = Self.table
        data.withUnsafeBytes { raw in
            for byte in raw {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ table[index]
            }
        }
        return crc ^ initial
    }

    /// Verify that `data`'s CRC32 matches `expected`. Returns `true` on
    /// match, `false` otherwise — callers translate the boolean into a
    /// suitable `RARError` for their context (header vs. data mismatch).
    public static func verify(_ data: Data, expected: UInt32) -> Bool {
        return compute(data) == expected
    }

    // MARK: - Table

    /// Precomputed lookup table for the reflected `0xEDB88320` polynomial.
    /// Built lazily and held for the process lifetime; 1 KB.
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        let poly: UInt32 = 0xEDB88320
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = poly ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            t[i] = c
        }
        return t
    }()
}
