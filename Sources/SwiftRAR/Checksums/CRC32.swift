import Foundation

/// The CRC-32 used throughout RAR (Reference §6.1): reflected polynomial
/// `0xEDB88320`, initial value and final XOR `0xFFFFFFFF`. Check value for
/// `"123456789"` is `0xCBF43926`.
///
/// RAR 1.5–4.x block headers store only the low 16 bits of this value
/// (Reference §6.2).
enum CRC32 {

    /// Byte-at-a-time lookup table, built once on first use.
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    /// Feed `buffer` into a running, *un-finalised* register value.
    private static func absorb(_ register: UInt32, _ buffer: UnsafeRawBufferPointer) -> UInt32 {
        var crc = register
        table.withUnsafeBufferPointer { lookup in
            for byte in buffer {
                crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc
    }

    /// CRC-32 of `data`.
    static func compute(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { absorb(0xFFFF_FFFF, $0) } ^ 0xFFFF_FFFF
    }

    /// CRC-32 of `bytes`.
    static func compute(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { absorb(0xFFFF_FFFF, $0) } ^ 0xFFFF_FFFF
    }

    /// CRC-32 of `bytes`.
    static func compute(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBytes { absorb(0xFFFF_FFFF, $0) } ^ 0xFFFF_FFFF
    }

    /// Whether the CRC-32 of `data` equals `expected`.
    static func verify(_ data: Data, expected: UInt32) -> Bool {
        compute(data) == expected
    }
}
