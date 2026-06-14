import Foundation
@testable import SwiftRAR

/// In-memory builder that constructs a syntactically valid RAR3 (classic)
/// archive containing STORE-method file entries. Used by the SwiftRAR test
/// suite so we don't have to ship binary fixtures.
///
/// The builder produces:
/// 1. The 7-byte MARK_HEAD signature (`"Rar!\x1A\x07\x00"`).
/// 2. A minimal MAIN_HEAD (0x73) block with zeroed HighPosAV/PosAV.
/// 3. One FILE_HEAD (0x74) + payload per entry added via `addStoredFile`.
/// 4. An ENDARC_HEAD (0x7B) block.
///
/// HEAD_CRC is written as zero — SwiftRAR's parser currently treats header
/// CRC verification as optional, matching the rarfile / libarchive default
/// for read-only enumeration. The header structure itself is bit-perfect.
struct RAR3FixtureBuilder {
    private struct PendingFile {
        let name: String
        let payload: Data
    }

    private var pending: [PendingFile] = []

    mutating func addStoredFile(name: String, payload: Data) {
        pending.append(PendingFile(name: name, payload: payload))
    }

    mutating func addStoredFile(name: String, text: String) {
        addStoredFile(name: name, payload: Data(text.utf8))
    }

    func build() -> Data {
        var data = Data()

        // 1. MARK_HEAD signature (RAR3).
        data.append(contentsOf: RARSignature.classicBytes)

        // 2. MAIN_HEAD: 13 bytes total.
        //    HEAD_CRC(2) | HEAD_TYPE(1)=0x73 | HEAD_FLAGS(2) | HEAD_SIZE(2)
        //    | HighPosAV(2) | PosAV(4)
        data.append(uint16LE: 0x0000)               // HEAD_CRC (unverified)
        data.append(0x73)                            // HEAD_TYPE
        data.append(uint16LE: 0x0000)                // HEAD_FLAGS
        data.append(uint16LE: 13)                    // HEAD_SIZE
        data.append(uint16LE: 0x0000)                // HighPosAV
        data.append(uint32LE: 0x00000000)            // PosAV

        // 3. FILE_HEAD blocks.
        for file in pending {
            let nameBytes = Array(file.name.utf8)  // ASCII assumption for fixtures.
            let nameSize = UInt16(nameBytes.count)
            // FILE_HEAD layout for SwiftRAR-supported shape (no LARGE, no
            // SALT, no EXTTIME, no UNICODE):
            //  HEAD_CRC(2) | HEAD_TYPE(1) | HEAD_FLAGS(2) | HEAD_SIZE(2)
            //  | PACK_SIZE(4) | UNP_SIZE(4) | HOST_OS(1) | FILE_CRC(4)
            //  | FTIME(4) | UNP_VER(1) | METHOD(1) | NAME_SIZE(2)
            //  | ATTR(4) | NAME(nameSize)
            // Fixed portion size = 7 + 25 = 32 bytes
            // Plus name bytes; HEAD_SIZE = 32 + nameSize.
            let headSize = UInt16(32 + Int(nameSize))

            let packed = UInt32(file.payload.count)
            let crc = CRC32.compute(file.payload)

            // Set LONG_BLOCK flag so the parser reads the embedded
            // PACK_SIZE / data-region length.
            let flags: UInt16 = 0x8000

            data.append(uint16LE: 0x0000)            // HEAD_CRC
            data.append(0x74)                         // HEAD_TYPE
            data.append(uint16LE: flags)              // HEAD_FLAGS
            data.append(uint16LE: headSize)           // HEAD_SIZE
            data.append(uint32LE: packed)             // PACK_SIZE
            data.append(uint32LE: packed)             // UNP_SIZE (== PACK_SIZE for STORE)
            data.append(0x02)                          // HOST_OS = Win32
            data.append(uint32LE: crc)                // FILE_CRC
            data.append(uint32LE: 0x00000000)         // FTIME (no time recorded)
            data.append(0x14)                          // UNP_VER = 2.0
            data.append(0x30)                          // METHOD = STORE
            data.append(uint16LE: nameSize)           // NAME_SIZE
            data.append(uint32LE: 0x00000020)         // ATTR (FILE_ATTRIBUTE_ARCHIVE)
            data.append(contentsOf: nameBytes)         // NAME
            data.append(file.payload)                  // packed data
        }

        // 4. ENDARC_HEAD: minimal 7-byte common header.
        data.append(uint16LE: 0x0000)                // HEAD_CRC
        data.append(0x7B)                             // HEAD_TYPE
        data.append(uint16LE: 0x0000)                 // HEAD_FLAGS
        data.append(uint16LE: 7)                      // HEAD_SIZE

        return data
    }
}

private extension Data {
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
