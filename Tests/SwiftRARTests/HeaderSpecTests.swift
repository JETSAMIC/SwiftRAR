import XCTest
@testable import SwiftRAR

/// Header-level behaviour derived from the RAR 1.5–4.x block format
/// (`Reference/RAR-Format.md` §3).
final class HeaderSpecTests: XCTestCase {

    private func singleEntry(_ configure: (inout RAR3FixtureBuilder.File) -> Void) throws -> (RAREntry, Data) {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "file.txt", text: "payload")
        configure(&builder.files[0])
        let archive = builder.build()
        return (try RARArchive.entries(archive)[0], archive)
    }

    // MARK: HEAD_CRC

    func testFileHeaderCRCMismatchIsReported() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "file.txt", text: "payload")
        var archive = builder.build()
        // FILE_HEAD starts at 7 + 13 = 20; its name starts 32 bytes later.
        archive[20 + 32] ^= 0x01
        XCTAssertThrowsError(try RARArchive.entries(archive)) {
            XCTAssertEqual($0 as? RARError, .headerCRCMismatch)
        }
    }

    func testMainHeaderCRCMismatchIsReported() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        var archive = builder.build()
        archive[7] ^= 0xFF  // HEAD_CRC low byte of MAIN_HEAD
        XCTAssertThrowsError(try RARArchive.entries(archive)) {
            XCTAssertEqual($0 as? RARError, .headerCRCMismatch)
        }
    }

    func testEndArchiveCRCMismatchIsReported() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        var archive = builder.build()
        archive[archive.count - 7] ^= 0xFF
        XCTAssertThrowsError(try RARArchive.entries(archive)) {
            XCTAssertEqual($0 as? RARError, .headerCRCMismatch)
        }
    }

    /// RAR ≤ 2.x embeds the archive comment in MAIN_HEAD (MHD_COMMENT); the
    /// header CRC then covers only the fixed 13 bytes.
    func testEmbeddedMainCommentCRCCoversFixedPartOnly() throws {
        var data = Data(RARSignature.classicBytes)
        var fixed = Data([0x73])
        fixed.append(uint16LE: 0x0002)          // MHD_COMMENT
        fixed.append(uint16LE: 13 + 6)          // HEAD_SIZE incl. comment
        fixed.append(contentsOf: [0, 0, 0, 0, 0, 0])
        data.append(uint16LE: UInt16(truncatingIfNeeded: CRC32.compute(fixed)))
        data.append(fixed)
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]) // embedded comment block
        var end = Data([0x7B])
        end.append(uint16LE: 0)
        end.append(uint16LE: 7)
        data.appendBlock(end)
        XCTAssertEqual(try RARArchive.entries(data), [])
    }

    // MARK: Block walking

    func testUnknownAndServiceBlocksAreSkipped() throws {
        var data = Data(RARSignature.classicBytes)
        var main = Data([0x73])
        main.append(uint16LE: 0)
        main.append(uint16LE: 13)
        main.append(contentsOf: [0, 0, 0, 0, 0, 0])
        data.appendBlock(main)
        // Unknown block 0x7F with LONG_BLOCK and 3 bytes of payload.
        var unknown = Data([0x7F])
        unknown.append(uint16LE: 0x8000)
        unknown.append(uint16LE: 11)
        unknown.append(uint32LE: 3)
        data.appendBlock(unknown)
        data.append(contentsOf: [1, 2, 3])
        // NEWSUB (service) header "CMT" with a 2-byte payload.
        var sub = Data([0x7A])
        sub.append(uint16LE: 0x8000)
        sub.append(uint16LE: 35)
        sub.append(uint32LE: 2)        // PACK_SIZE
        sub.append(uint32LE: 2)        // UNP_SIZE
        sub.append(2)
        sub.append(uint32LE: 0)
        sub.append(uint32LE: 0)
        sub.append(29)
        sub.append(0x30)
        sub.append(uint16LE: 3)
        sub.append(uint32LE: 0)
        sub.append(contentsOf: Array("CMT".utf8))
        data.appendBlock(sub)
        data.append(contentsOf: [9, 9])

        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "after.txt", text: "after")
        let tail = builder.build().dropFirst(7 + 13)   // FILE_HEAD + ENDARC
        data.append(tail)

        let entries = try RARArchive.entries(data)
        XCTAssertEqual(entries.map(\.name), ["after.txt"])
        XCTAssertEqual(try RARArchive.extract(entry: entries[0], from: data), Data("after".utf8))
    }

    func testMissingEndMarkerIsAccepted() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        builder.includeEndMarker = false
        XCTAssertEqual(try RARArchive.entries(builder.build()).count, 1)
    }

    func testDataSliceWithNonZeroStartIndex() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a.txt", text: "slice")
        let padded = Data([0xEE, 0xEE, 0xEE]) + builder.build()
        let slice = padded[3...]
        let entries = try RARArchive.entries(slice)
        XCTAssertEqual(try RARArchive.extract(entry: entries[0], from: slice), Data("slice".utf8))
    }

    // MARK: Archive and entry flags

    func testVolumeAndEncryptedHeaderArchivesAreRejected() {
        for (flags, feature) in [(UInt16(0x0001), RARFeature.multiVolume), (0x0080, .encryptedHeaders)] {
            var builder = RAR3FixtureBuilder()
            builder.mainFlags = flags
            builder.addStoredFile(name: "a", text: "a")
            XCTAssertThrowsError(try RARArchive.entries(builder.build())) {
                XCTAssertEqual($0 as? RARError, .unsupportedFeature(feature))
            }
        }
    }

    func testEncryptedAndSolidEntriesListButDoNotExtract() throws {
        for (flags, feature) in [(UInt16(0x0004), RARFeature.encryptedEntry), (0x0010, .solidEntry)] {
            let (entry, archive) = try singleEntry { $0.flags = flags }
            XCTAssertEqual(entry.isEncrypted, feature == .encryptedEntry)
            XCTAssertEqual(entry.isSolid, feature == .solidEntry)
            XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive)) {
                XCTAssertEqual($0 as? RARError, .unsupportedFeature(feature))
            }
        }
    }

    func testDirectoryEntry() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "dir", payload: Data())
        builder.files[0].flags = 0x00E0
        builder.files[0].attributes = 0x10
        let archive = builder.build()
        let entry = try RARArchive.entries(archive)[0]
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(try RARArchive.extract(entry: entry, from: archive), Data())
    }

    func testLargeFlagReadsHighSizeWords() throws {
        // LHD_LARGE with a high PACK_SIZE word: the payload cannot fit.
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "", text: "x")
        builder.files[0].flags = 0x0100
        builder.files[0].nameBytes = []
        // HIGH_PACK_SIZE = 1, HIGH_UNP_SIZE = 1 go before the (empty) name.
        builder.files[0].trailer = [1, 0, 0, 0, 1, 0, 0, 0]
        XCTAssertThrowsError(try RARArchive.entries(builder.build())) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    func testHeaderTooSmallForFixedFieldsIsMalformed() {
        var data = Data(RARSignature.classicBytes)
        var main = Data([0x73])
        main.append(uint16LE: 0)
        main.append(uint16LE: 13)
        main.append(contentsOf: [0, 0, 0, 0, 0, 0])
        data.appendBlock(main)
        var file = Data([0x74])
        file.append(uint16LE: 0x8000)
        file.append(uint16LE: 20)               // < 32
        file.append(contentsOf: [UInt8](repeating: 0, count: 13))
        data.appendBlock(file)
        XCTAssertThrowsError(try RARArchive.entries(data)) {
            XCTAssertEqual($0 as? RARError, .malformedHeader)
        }
    }

    func testStoredSizeMismatchIsCorrupt() throws {
        let (entry, archive) = try singleEntry { $0.unpackedSize = 3 }
        XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    // MARK: File names

    func testUnicodeFlagWithoutSeparatorIsUTF8() throws {
        let (entry, _) = try singleEntry {
            $0.nameBytes = Array("Grüße/日本.txt".utf8)
            $0.flags = 0x0200
        }
        XCTAssertEqual(entry.name, "Grüße/日本.txt")
    }

    /// Compact UTF-16: high byte 0x04, flags 11 00 10 00 →
    /// op3 (copy 2 OEM chars with correction 0 and high byte), op0 (`-`),
    /// op2 (U+20AC).
    func testCompactUTF16Name() throws {
        let oem: [UInt8] = Array("AB-?".utf8)
        let encoded: [UInt8] = [0x04, 0xC8, 0x80, 0x00, 0x2D, 0xAC, 0x20]
        let (entry, _) = try singleEntry {
            $0.nameBytes = oem + [0] + encoded
            $0.flags = 0x0200
        }
        XCTAssertEqual(entry.name, "ст-€")
    }

    /// Op 1 (low byte + shared high byte) followed by an uncorrected op3
    /// copy of four OEM characters.
    func testCompactUTF16NameWithPlainOEMCopy() throws {
        let decoded = ClassicFileName.decodeCompactUTF16(
            oem: Array("x.txt".utf8),
            encoded: [0x04, 0x70, 0x16, 0x02]
        )
        XCTAssertEqual(decoded, "Ж.txt")
    }

    func testOEMNameFallsBackToCP437() throws {
        let (entry, _) = try singleEntry { $0.nameBytes = [0x8E, 0x2E, 0xE1, 0xB0] }
        XCTAssertEqual(entry.name, "Ä.ß░")
    }

    func testBackslashesAreSeparatorsForDOSHostsOnly() throws {
        let (windows, _) = try singleEntry { $0.nameBytes = Array("dir\\file".utf8) }
        XCTAssertEqual(windows.name, "dir/file")
        let (unix, _) = try singleEntry {
            $0.nameBytes = Array("dir\\file".utf8)
            $0.hostOS = 3
        }
        XCTAssertEqual(unix.name, "dir\\file")
    }

    func testCP437TableIsComplete() {
        let all = CP437.decode(Array(0x80...0xFF))
        XCTAssertEqual(all.unicodeScalars.count, 128)
    }

    // MARK: Path safety

    func testSanitizedPath() throws {
        let cases: [(String, String?)] = [
            ("docs/readme.txt", "docs/readme.txt"),
            ("/etc/passwd", "etc/passwd"),
            ("../../etc/passwd", nil),
            ("a/../../b", nil),
            ("a\\..\\b", nil),
            ("C:\\Windows\\system.ini", "Windows/system.ini"),
            ("C:relative.txt", "relative.txt"),
            ("\\\\server\\share\\f", "server/share/f"),
            ("a/./b//c", "a/b/c"),
            ("...", "..."),
            ("", nil),
            ("/", nil),
        ]
        for (raw, expected) in cases {
            let (entry, _) = try singleEntry {
                $0.nameBytes = Array(raw.utf8)
                $0.hostOS = 3
            }
            XCTAssertEqual(entry.sanitizedPath, expected, "name: \(raw)")
        }
    }

    func testSymbolicLinkDetection() throws {
        let (link, _) = try singleEntry {
            $0.hostOS = 3
            $0.attributes = 0o120777
        }
        XCTAssertTrue(link.isSymbolicLink)
        let (file, _) = try singleEntry { $0.hostOS = 3; $0.attributes = 0o100644 }
        XCTAssertFalse(file.isSymbolicLink)
    }

    // MARK: Timestamps

    private static func dos(_ y: UInt32, _ mo: UInt32, _ d: UInt32, _ h: UInt32, _ mi: UInt32, _ s: UInt32) -> UInt32 {
        ((y - 1980) << 25) | (mo << 21) | (d << 16) | (h << 11) | (mi << 5) | (s / 2)
    }

    func testDOSTimestampIsDecodedAsUTC() throws {
        let (entry, _) = try singleEntry { $0.ftime = Self.dos(2020, 1, 2, 3, 4, 6) }
        XCTAssertEqual(entry.modificationDate, Date(timeIntervalSince1970: 1_577_934_246))
    }

    func testInvalidDOSTimestampIsNil() throws {
        let (entry, _) = try singleEntry { $0.ftime = Self.dos(2020, 13, 2, 3, 4, 6) }
        XCTAssertNil(entry.modificationDate)
        let (zeroDay, _) = try singleEntry { $0.ftime = Self.dos(2020, 2, 30, 3, 4, 6) }
        XCTAssertNil(zeroDay.modificationDate)
    }

    /// EXT_TIME mtime nibble 0xF: present, +1 s, 3 remainder bytes holding
    /// 5 000 000 × 100 ns = 0.5 s.
    func testExtendedTimeRefinesModificationDate() throws {
        let (entry, _) = try singleEntry {
            $0.ftime = Self.dos(2020, 1, 2, 3, 4, 6)
            $0.flags = 0x1000
            $0.trailer = [0x00, 0xF0, 0x40, 0x4B, 0x4C]
        }
        XCTAssertEqual(entry.modificationDate, Date(timeIntervalSince1970: 1_577_934_247.5))
    }

    func testTruncatedExtendedTimeIsMalformed() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        builder.files[0].ftime = Self.dos(2020, 1, 2, 3, 4, 6)
        builder.files[0].flags = 0x1000
        builder.files[0].trailer = [0x00, 0xF0, 0x40]
        XCTAssertThrowsError(try RARArchive.entries(builder.build())) {
            XCTAssertEqual($0 as? RARError, .malformedHeader)
        }
    }
}

/// Container rules added with the clean-room parser (Reference §3, §6.2).
final class ContainerRuleTests: XCTestCase {

    /// RAR ≤ 2.x file comments follow the name and have their own CRC; the
    /// FILE_HEAD CRC then ends at the name (Reference §6.2).
    func testEmbeddedFileCommentCRCEndsAtName() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "c.txt", text: "commented")
        builder.files[0].flags = 0x0008
        builder.files[0].trailer = [0x11, 0x22, 0x33, 0x44, 0x55]
        var archive = builder.build()
        let start = 7 + 13
        let nameEnd = start + 32 + 5
        let crc = UInt16(truncatingIfNeeded: CRC32.compute(archive[(start + 2)..<nameEnd]))
        archive[start] = UInt8(crc & 0xFF)
        archive[start + 1] = UInt8(crc >> 8)
        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.map(\.name), ["c.txt"])
        XCTAssertEqual(try RARArchive.extract(entry: entries[0], from: archive), Data("commented".utf8))

        archive[nameEnd + 1] ^= 0xFF  // comment bytes are not covered
        XCTAssertNoThrow(try RARArchive.entries(archive))
        archive[nameEnd - 1] ^= 0xFF  // the name is
        XCTAssertThrowsError(try RARArchive.entries(archive)) {
            XCTAssertEqual($0 as? RARError, .headerCRCMismatch)
        }
    }

    func testSplitEntriesAreVolumePieces() {
        for flags: UInt16 in [0x0001, 0x0002] {
            var builder = RAR3FixtureBuilder()
            builder.addStoredFile(name: "part", text: "piece")
            builder.files[0].flags = flags
            XCTAssertThrowsError(try RARArchive.entries(builder.build())) {
                XCTAssertEqual($0 as? RARError, .unsupportedFeature(.multiVolume))
            }
        }
    }

    func testFirstBlockMustBeMainHeader() {
        var data = Data(RARSignature.classicBytes)
        var end = Data([0x7B])
        end.append(uint16LE: 0x4000)
        end.append(uint16LE: 7)
        data.appendBlock(end)
        XCTAssertThrowsError(try RARArchive.entries(data)) {
            XCTAssertEqual($0 as? RARError, .malformedHeader)
        }
    }

    func testNothingAfterEndBlockIsRead() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        let archive = builder.build() + Data([0xDE, 0xAD])
        XCTAssertEqual(try RARArchive.entries(archive).count, 1)
    }

    func testPartialBlockHeaderAtEndIsTruncation() {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a", text: "a")
        builder.includeEndMarker = false
        let archive = builder.build() + Data([0x00, 0x00, 0x7B])
        XCTAssertThrowsError(try RARArchive.entries(archive)) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    func testLegacyBlocksAreSkippedByAddSize() throws {
        var data = Data(RARSignature.classicBytes)
        var main = Data([0x73])
        main.append(uint16LE: 0)
        main.append(uint16LE: 13)
        main.append(contentsOf: [0, 0, 0, 0, 0, 0])
        data.appendBlock(main)
        // PROTECT_HEAD with LONG_BLOCK, 4 bytes of payload and a CRC that
        // does not match: legacy blocks are skipped unchecked.
        data.append(contentsOf: [0xAA, 0xBB, 0x78, 0x00, 0x80, 0x0B, 0x00, 0x04, 0x00, 0x00, 0x00])
        data.append(contentsOf: [9, 9, 9, 9])
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "after", text: "x")
        data.append(builder.build().dropFirst(7 + 13))
        XCTAssertEqual(try RARArchive.entries(data).map(\.name), ["after"])
    }
}
