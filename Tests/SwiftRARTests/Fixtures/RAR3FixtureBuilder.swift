import Foundation
@testable import SwiftRAR

/// In-memory builder for syntactically valid RAR 1.5–4.x archives, so the
/// test suite needs no binary fixtures.
///
/// The builder produces:
/// 1. The 7-byte MARK_HEAD signature (`"Rar!\x1A\x07\x00"`).
/// 2. A MAIN_HEAD (0x73) block with zeroed HighPosAV/PosAV.
/// 3. One FILE_HEAD (0x74) + payload per entry.
/// 4. An ENDARC_HEAD (0x7B) block.
///
/// Every HEAD_CRC is the low 16 bits of the CRC-32 of the header bytes that
/// follow it, exactly as RAR writes it, so the parser's verification passes.
struct RAR3FixtureBuilder {
    /// One FILE_HEAD plus payload.
    struct File {
        var nameBytes: [UInt8]
        var packed: Data
        var unpackedSize: UInt64
        var crc: UInt32
        var method: UInt8 = 0x30
        var unpackVersion: UInt8 = 0x14
        var flags: UInt16 = 0
        var hostOS: UInt8 = 0x02
        var ftime: UInt32 = 0
        var attributes: UInt32 = 0x20
        /// Raw bytes appended after the name (SALT, EXT_TIME…).
        var trailer: [UInt8] = []
    }

    var mainFlags: UInt16 = 0
    var files: [File] = []
    var includeEndMarker = true

    mutating func addStoredFile(name: String, payload: Data) {
        files.append(File(
            nameBytes: Array(name.utf8),
            packed: payload,
            unpackedSize: UInt64(payload.count),
            crc: CRC32.compute(payload)
        ))
    }

    mutating func addStoredFile(name: String, text: String) {
        addStoredFile(name: name, payload: Data(text.utf8))
    }

    /// Add an entry compressed with the RAR 2.9 format whose decoded content
    /// is `unpacked`.
    mutating func addCompressedFile(name: String, packed: Data, unpacked: Data, method: UInt8 = 0x33) {
        files.append(File(
            nameBytes: Array(name.utf8),
            packed: packed,
            unpackedSize: UInt64(unpacked.count),
            crc: CRC32.compute(unpacked),
            method: method,
            unpackVersion: 29
        ))
    }

    func build() -> Data {
        var data = Data(RARSignature.classicBytes)

        // MAIN_HEAD: 13 bytes total.
        var main = Data()
        main.append(0x73)                         // HEAD_TYPE
        main.append(uint16LE: mainFlags)          // HEAD_FLAGS
        main.append(uint16LE: 13)                 // HEAD_SIZE
        main.append(uint16LE: 0x0000)             // HighPosAV
        main.append(uint32LE: 0x00000000)         // PosAV
        data.appendBlock(main)

        for file in files {
            // Fixed portion = 7 + 25 = 32 bytes, then NAME and trailer.
            let headSize = UInt16(32 + file.nameBytes.count + file.trailer.count)
            var header = Data()
            header.append(0x74)                              // HEAD_TYPE
            header.append(uint16LE: 0x8000 | file.flags)     // HEAD_FLAGS (LONG_BLOCK)
            header.append(uint16LE: headSize)                // HEAD_SIZE
            header.append(uint32LE: UInt32(file.packed.count)) // PACK_SIZE
            header.append(uint32LE: UInt32(truncatingIfNeeded: file.unpackedSize)) // UNP_SIZE
            header.append(file.hostOS)                       // HOST_OS
            header.append(uint32LE: file.crc)                // FILE_CRC
            header.append(uint32LE: file.ftime)              // FTIME
            header.append(file.unpackVersion)                // UNP_VER
            header.append(file.method)                       // METHOD
            header.append(uint16LE: UInt16(file.nameBytes.count)) // NAME_SIZE
            header.append(uint32LE: file.attributes)         // ATTR
            header.append(contentsOf: file.nameBytes)        // NAME
            header.append(contentsOf: file.trailer)
            data.appendBlock(header)
            data.append(file.packed)
        }

        if includeEndMarker {
            var end = Data()
            end.append(0x7B)                      // HEAD_TYPE
            end.append(uint16LE: 0x4000)          // HEAD_FLAGS (SKIP_IF_UNKNOWN, as RAR 3.x writes it)
            end.append(uint16LE: 7)               // HEAD_SIZE
            data.appendBlock(end)
        }
        return data
    }
}

extension Data {
    /// Append `HEAD_CRC` (low 16 bits of CRC-32 over `body`) followed by
    /// `body`, which must start at HEAD_TYPE.
    mutating func appendBlock(_ body: Data) {
        append(uint16LE: UInt16(truncatingIfNeeded: CRC32.compute(body)))
        append(body)
    }

    mutating func append(uint16LE value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32LE value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// MSB-first bit writer (the inverse of `BitStream`).
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var buffer: UInt64 = 0
    private var bitsInBuffer = 0

    mutating func write(_ value: UInt32, bits: Int) {
        precondition(bits > 0 && bits <= 32)
        let masked = UInt64(value) & ((UInt64(1) << bits) - 1)
        buffer |= masked << (64 - bitsInBuffer - bits)
        bitsInBuffer += bits
        while bitsInBuffer >= 8 {
            bytes.append(UInt8(buffer >> 56))
            buffer <<= 8
            bitsInBuffer -= 8
        }
    }

    mutating func alignToByte() {
        if bitsInBuffer > 0 { write(0, bits: 8 - bitsInBuffer) }
    }

    func finished() -> Data {
        var copy = self
        copy.alignToByte()
        return Data(copy.bytes)
    }
}

/// Encoder for hand-built RAR 2.9 LZ streams, using fixed, easy-to-read
/// Huffman tables:
///
/// - pre-code: all 20 symbols length 5 (symbol `k` ↔ code `k`);
/// - main: all 299 symbols length 9; distance slot: all 60 length 6;
///   low distance: all 17 length 5; length: all 28 length 5.
///
/// Every canonical code therefore equals its symbol number written in the
/// table's bit width, so streams can be checked by hand against the spec.
/// The static tables below are typed in from Reference §6.3.7 rather than
/// taken from the implementation, so the tests check the decoder against
/// the document.
struct RAR29StreamWriter {
    static let tableLengths: [UInt8] =
        Array(repeating: 9, count: 299) + Array(repeating: 6, count: 60)
        + Array(repeating: 5, count: 17) + Array(repeating: 5, count: 28)

    /// Reference §6.3.7, length codes.
    static let lengthBase = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28,
                             32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5]
    /// Reference §6.3.7, short distances.
    static let shortExtra = [2, 2, 3, 4, 5, 6, 6, 6]
    /// Reference §6.3.7, distance-slot table rows (first slot, extra bits, first base).
    static let slotRows: [(first: Int, last: Int, extra: Int, base: Int)] = [
        (0, 3, 0, 0), (4, 5, 1, 4), (6, 7, 2, 8), (8, 9, 3, 16), (10, 11, 4, 32),
        (12, 13, 5, 64), (14, 15, 6, 128), (16, 17, 7, 256), (18, 19, 8, 512),
        (20, 21, 9, 1_024), (22, 23, 10, 2_048), (24, 25, 11, 4_096), (26, 27, 12, 8_192),
        (28, 29, 13, 16_384), (30, 31, 14, 32_768), (32, 33, 15, 65_536),
        (34, 47, 16, 131_072), (48, 59, 18, 1_048_576),
    ]

    static func slot(_ slot: Int) -> (base: Int, extra: Int) {
        let row = slotRows.first { $0.first <= slot && slot <= $0.last }!
        return (row.base + (slot - row.first) << row.extra, row.extra)
    }

    var bits = BitWriter()

    /// Emit a block header and tables. `keep` sets the keep-old-table flag
    /// and sends all-zero deltas (i.e. the same table again).
    mutating func tables(keep: Bool = false, ppm: Bool = false) {
        bits.alignToByte()
        bits.write(ppm ? 1 : 0, bits: 1)
        bits.write(keep ? 1 : 0, bits: 1)
        if ppm { return }
        for _ in 0..<20 { bits.write(5, bits: 4) }
        for length in Self.tableLengths {
            bits.write(keep ? 0 : UInt32(length), bits: 5)
        }
    }

    mutating func literal(_ byte: UInt8) { bits.write(UInt32(byte), bits: 9) }

    mutating func literals<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { literal(byte) }
    }

    mutating func endOfFile() {
        bits.write(256, bits: 9)
        bits.write(0, bits: 2)
    }

    mutating func newTablesFollow(keep: Bool) {
        bits.write(256, bits: 9)
        bits.write(1, bits: 1)
        tables(keep: keep)
    }

    mutating func filter() { bits.write(257, bits: 9) }

    mutating func repeatLastMatch() { bits.write(258, bits: 9) }

    /// Symbols 259…262 with a length-alphabet code.
    mutating func recentDistance(_ index: Int, lengthCode: Int, lengthExtra: UInt32 = 0) {
        bits.write(UInt32(259 + index), bits: 9)
        bits.write(UInt32(lengthCode), bits: 5)
        let extra = Self.lengthExtra[lengthCode]
        if extra > 0 { bits.write(lengthExtra, bits: extra) }
    }

    /// Symbols 263…270.
    mutating func shortMatch(_ index: Int, extra: UInt32 = 0) {
        bits.write(UInt32(263 + index), bits: 9)
        bits.write(extra, bits: Self.shortExtra[index])
    }

    /// Symbols 271…298: encode a long match of the *final* `length` (after
    /// the decoder's +1/+2 long-distance bonus) at `distance`.
    mutating func longMatch(length: Int, distance: Int) {
        var coded = length - 3
        if distance >= 0x2000 { coded -= 1 }
        if distance >= 0x40000 { coded -= 1 }
        let code = Self.lengthBase.lastIndex { $0 <= coded }!
        bits.write(UInt32(271 + code), bits: 9)
        let lengthBits = Self.lengthExtra[code]
        if lengthBits > 0 {
            bits.write(UInt32(coded - Self.lengthBase[code]), bits: lengthBits)
        }
        let slot = (0..<60).last { Self.slot($0).base + 1 <= distance }!
        bits.write(UInt32(slot), bits: 6)
        let (base, distanceBits) = Self.slot(slot)
        let extra = distance - 1 - base
        if distanceBits == 0 { return }
        if slot > 9 {
            if distanceBits > 4 { bits.write(UInt32(extra >> 4), bits: distanceBits - 4) }
            bits.write(UInt32(extra & 0xF), bits: 5)
        } else {
            bits.write(UInt32(extra), bits: distanceBits)
        }
    }

    func finished() -> Data { bits.finished() }
}

/// Deterministic SplitMix64 generator for reproducible fuzzing.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
