import Foundation

/// Decoding of FILE_HEAD names (Reference §3.13).
enum ClassicFileName {

    /// Turn a raw FILE_NAME field into a display name.
    ///
    /// - Parameters:
    ///   - field: The NAME_SIZE bytes of the header.
    ///   - hasUnicode: Whether `LHD_UNICODE` is set.
    ///   - hostOS: The HOST_OS byte; hosts 0–2 use `\` as separator, which
    ///     is converted to `/`.
    static func decode(_ field: [UInt8], hasUnicode: Bool, hostOS: UInt8) -> String {
        var name: String
        if hasUnicode {
            if let zero = field.firstIndex(of: 0) {
                let narrow = Array(field[..<zero])
                let wide = decodeCompactUTF16(oem: narrow, encoded: Array(field[(zero + 1)...]))
                name = wide.isEmpty ? decodeNarrow(narrow) : wide
            } else {
                name = decodeNarrow(field)
            }
        } else {
            name = decodeNarrow(field)
        }
        if hostOS <= 2 {
            name = name.replacingOccurrences(of: "\\", with: "/")
        }
        return name
    }

    /// An 8-bit name: UTF-8 when the bytes are valid UTF-8, otherwise IBM
    /// code page 437 (the usual DOS OEM code page).
    static func decodeNarrow(_ bytes: [UInt8]) -> String {
        if let text = String(bytes: bytes, encoding: .utf8) {
            return text
        }
        return CP437.decode(bytes)
    }

    /// Expand RAR's compact UTF-16 name encoding (Reference §3.13).
    ///
    /// - Parameters:
    ///   - oem: The 8-bit name that precedes the zero separator.
    ///   - encoded: The bytes after the separator.
    /// - Returns: The decoded name; empty if nothing could be decoded.
    static func decodeCompactUTF16(oem: [UInt8], encoded: [UInt8]) -> String {
        guard let high = encoded.first else { return "" }
        let highBits = UInt16(high) << 8
        var units: [UInt16] = []
        var cursor = 1
        var opcodes = 0
        var opcodesLeft = 0

        decoding: while cursor < encoded.count {
            if opcodesLeft == 0 {
                opcodes = Int(encoded[cursor])
                cursor += 1
                opcodesLeft = 4
                continue
            }
            let op = (opcodes >> 6) & 0x03
            opcodes = (opcodes << 2) & 0xFF
            opcodesLeft -= 1

            // The loop condition guarantees one byte is available here.
            switch op {
            case 0:
                units.append(UInt16(encoded[cursor]))
                cursor += 1
            case 1:
                units.append(highBits | UInt16(encoded[cursor]))
                cursor += 1
            case 2:
                guard cursor + 1 < encoded.count else { break decoding }
                units.append(UInt16(encoded[cursor + 1]) << 8 | UInt16(encoded[cursor]))
                cursor += 2
            default:
                let run = encoded[cursor]
                cursor += 1
                if run & 0x80 != 0 {
                    guard cursor < encoded.count else { break decoding }
                    let adjust = encoded[cursor]
                    cursor += 1
                    for _ in 0..<(Int(run & 0x7F) + 2) where units.count < oem.count {
                        units.append(highBits | UInt16(oem[units.count] &+ adjust))
                    }
                } else {
                    for _ in 0..<(Int(run) + 2) where units.count < oem.count {
                        units.append(UInt16(oem[units.count]))
                    }
                }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// IBM code page 437, the default OEM character set of MS-DOS.
enum CP437 {

    /// Unicode scalars for bytes `0x80`–`0xFF` (bytes below `0x80` are ASCII).
    private static let upperHalf: [UInt32] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    /// Decode `bytes` as code page 437.
    static func decode(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte < 0x80 ? UInt32(byte) : upperHalf[Int(byte) - 0x80]
            // Every table entry is a valid scalar; the fallback is unreachable.
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}
