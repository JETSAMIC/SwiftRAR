import Foundation

/// MS-DOS packed date/time (Reference §3.12), optionally refined by the
/// sub-second data of an EXT_TIME record (§3.11).
///
/// RAR stores local wall-clock time with no zone; SwiftRAR reads the fields
/// as UTC.
enum DOSTimestamp {

    /// Convert a packed DOS value to a `Date`, or `nil` when any field is out
    /// of range (month 0, 30 February, second 60, …).
    ///
    /// - Parameters:
    ///   - packed: The 32-bit DOS value (date in the high half).
    ///   - extraSecond: Adds one second (EXT_TIME group bit 2).
    ///   - hundredNanoseconds: Sub-second offset from EXT_TIME, in 100 ns units.
    static func date(_ packed: UInt32, extraSecond: Bool = false, hundredNanoseconds: UInt32 = 0) -> Date? {
        let year = 1980 + Int(packed >> 25)
        let month = Int((packed >> 21) & 0x0F)
        let day = Int((packed >> 16) & 0x1F)
        let hour = Int((packed >> 11) & 0x1F)
        let minute = Int((packed >> 5) & 0x3F)
        let second = Int(packed & 0x1F) * 2

        guard (1...12).contains(month),
              day >= 1, day <= daysIn(month: month, year: year),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }

        var days = 0
        for y in 1970..<year {
            days += isLeap(y) ? 366 : 365
        }
        for m in 1..<month {
            days += daysIn(month: m, year: year)
        }
        days += day - 1

        let wholeSeconds = days * 86_400 + hour * 3_600 + minute * 60 + second + (extraSecond ? 1 : 0)
        return Date(timeIntervalSince1970: Double(wholeSeconds) + Double(hundredNanoseconds) / 10_000_000)
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

/// The parts of an EXT_TIME record (Reference §3.11) that SwiftRAR uses:
/// the refinement of the modification time. The creation, access and
/// archive times are validated and skipped.
struct ExtendedTime: Equatable {
    /// Whether the mtime group was present.
    var hasModification = false
    /// Group bit 2: add one second to FTIME.
    var modificationExtraSecond = false
    /// Sub-second part of the modification time in 100 ns units.
    var modificationFraction: UInt32 = 0

    /// Parse an EXT_TIME record at the reader's position.
    ///
    /// - Throws: ``RARError/malformedHeader`` when a record does not fit in
    ///   the header.
    static func parse(_ reader: inout FieldReader) throws -> ExtendedTime {
        let flags = try reader.uint16()
        var result = ExtendedTime()
        // Groups from the top nibble down: mtime, ctime, atime, arctime.
        for (index, shift) in [12, 8, 4, 0].enumerated() {
            let group = (flags >> UInt16(shift)) & 0x0F
            guard group & 0x08 != 0 else { continue }
            let isModification = index == 0
            if !isModification {
                try reader.skip(4)  // own DOS time; mtime uses FTIME
            }
            let count = Int(group & 0x03)
            let stored = try reader.bytes(count)
            // The stored bytes are the most significant `count` bytes of a
            // 24-bit little-endian quantity.
            var fraction: UInt32 = 0
            for (j, byte) in stored.enumerated() {
                fraction |= UInt32(byte) << UInt32(8 * (3 - count + j))
            }
            if isModification {
                result.hasModification = true
                result.modificationExtraSecond = group & 0x04 != 0
                result.modificationFraction = fraction
            }
        }
        return result
    }
}
