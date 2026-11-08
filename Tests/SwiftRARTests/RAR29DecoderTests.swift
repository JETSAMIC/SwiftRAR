import XCTest
@testable import SwiftRAR

/// Spec-derived tests for the RAR 2.9 LZ decoder. Every stream is built by
/// `RAR29StreamWriter` from the bit layout in `Reference/RAR-Format.md` §6.3.
final class RAR29DecoderTests: XCTestCase {

    private func decode(_ writer: RAR29StreamWriter, size: Int) throws -> [UInt8] {
        [UInt8](try LZ29Decoder.decode(writer.finished(), outputSize: size))
    }

    func testLiteralsOnly() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("hello".utf8))
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 5), Array("hello".utf8))
    }

    /// Main symbol 271 is long-match length code 0 (length 3), not a short
    /// match (Reference §6.3.6).
    func testSymbol271IsLongMatchLengthCodeZero() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("abc".utf8))
        w.longMatch(length: 3, distance: 3)
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 6), Array("abcabc".utf8))
    }

    func testOverlappingLongMatchRepeatsPattern() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("ab".utf8))
        w.longMatch(length: 10, distance: 2)
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 12), Array("abababababab".utf8))
    }

    /// Distances ≥ 0x2000 add one to the coded length, ≥ 0x40000 add two.
    func testLongDistanceLengthBonus() throws {
        var prefix: [UInt8] = []
        var rng = SplitMix64(seed: 7)
        for _ in 0..<0x2000 { prefix.append(UInt8.random(in: 0...255, using: &rng)) }

        var w = RAR29StreamWriter()
        w.tables()
        w.literals(prefix)
        // Coded length code 1 (= 4) + bonus 1 = 5 bytes from 0x2000 back.
        w.longMatch(length: 5, distance: 0x2000)
        w.endOfFile()
        let out = try decode(w, size: prefix.count + 5)
        XCTAssertEqual(Array(out[prefix.count...]), Array(prefix[0..<5]))
    }

    /// Slots above 9 split the extra bits: high bits raw, low nibble from the
    /// low-distance alphabet; symbol 16 repeats the previous nibble.
    func testLowDistanceAlphabetAndRepeat() throws {
        var prefix: [UInt8] = []
        for i in 0..<200 { prefix.append(UInt8(truncatingIfNeeded: i &* 37)) }
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(prefix)
        w.longMatch(length: 3, distance: 0x75)          // slot 13, low nibble 4
        // Same slot again using the low-distance repeat symbol (16):
        // slot 13 base 96, 5 extra bits → high bit 1, nibble from repeat.
        w.bits.write(UInt32(271), bits: 9)               // length code 0 → 3
        w.bits.write(13, bits: 6)                        // distance slot 13
        w.bits.write(1, bits: 1)                         // high bit
        w.bits.write(16, bits: 5)                        // low-distance repeat
        w.endOfFile()
        let out = try decode(w, size: 206)
        var expected = prefix
        for _ in 0..<3 { expected.append(expected[expected.count - 0x75]) }
        for _ in 0..<3 { expected.append(expected[expected.count - (96 + 1 + 16 + 4)]) }
        XCTAssertEqual(out, expected)
    }

    /// Short matches: symbols 263…270, length 2, distance base+1+extra.
    func testShortMatch() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("wxyz".utf8))
        w.shortMatch(0, extra: 3)   // distance 0 + 1 + 3 = 4
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 6), Array("wxyzwx".utf8))
    }

    /// New distances are pushed without move-to-front, so a repeated distance
    /// occupies two history slots (Reference §6.3.8).
    func testDistanceHistoryAllowsDuplicates() throws {
        let prefix = Array("0123456789".utf8)
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(prefix)
        w.longMatch(length: 3, distance: 10)    // history [10]
        w.longMatch(length: 3, distance: 4)     // history [4, 10]
        w.longMatch(length: 3, distance: 10)    // history [10, 4, 10]
        w.recentDistance(2, lengthCode: 0)      // slot 2 = 10 → length 2
        w.endOfFile()

        var expected = prefix
        func copy(_ length: Int, _ distance: Int) {
            for _ in 0..<length { expected.append(expected[expected.count - distance]) }
        }
        copy(3, 10); copy(3, 4); copy(3, 10); copy(2, 10)
        XCTAssertEqual(try decode(w, size: expected.count), expected)
    }

    /// Symbol 258 repeats the last length at the most recent distance;
    /// recent-distance symbols rotate the chosen slot to the front.
    func testRepeatLastMatchAndRecentDistanceRotation() throws {
        let prefix = Array("abcdefgh".utf8)
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(prefix)
        w.longMatch(length: 4, distance: 8)     // history [8]
        w.shortMatch(0, extra: 1)               // distance 2, history [2, 8]
        w.recentDistance(1, lengthCode: 1)      // distance 8, length 3; history [8, 2]
        w.repeatLastMatch()                     // length 3, distance 8
        w.endOfFile()

        var expected = prefix
        func copy(_ length: Int, _ distance: Int) {
            for _ in 0..<length { expected.append(expected[expected.count - distance]) }
        }
        copy(4, 8); copy(2, 2); copy(3, 8); copy(3, 8)
        XCTAssertEqual(try decode(w, size: expected.count), expected)
    }

    /// End-of-block `1` means a new table follows; with the keep flag the new
    /// lengths are deltas against the old ones (here: all zero → same table).
    func testNewTableWithKeepFlagIsReadAsDeltas() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("ab".utf8))
        w.newTablesFollow(keep: true)
        w.literals(Array("cd".utf8))
        w.newTablesFollow(keep: false)
        w.literals(Array("ef".utf8))
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 6), Array("abcdef".utf8))
    }

    func testOutputIsCappedAtDeclaredSize() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(0x41)
        w.longMatch(length: 200, distance: 1)
        w.endOfFile()
        XCTAssertEqual(try decode(w, size: 10), [UInt8](repeating: 0x41, count: 10))
    }

    func testPPMdBlockIsRejected() {
        var w = RAR29StreamWriter()
        w.tables(ppm: true)
        w.bits.write(0, bits: 16)
        XCTAssertThrowsError(try decode(w, size: 4)) {
            XCTAssertEqual($0 as? RARError, .unsupportedFeature(.ppmd))
        }
    }

    func testVMFilterIsRejected() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        w.filter()
        w.bits.write(0, bits: 32)
        XCTAssertThrowsError(try decode(w, size: 4)) {
            XCTAssertEqual($0 as? RARError, .unsupportedFeature(.vmFilter))
        }
    }

    func testMatchBeforeStartOfFileIsCorrupt() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        w.longMatch(length: 3, distance: 5)
        w.endOfFile()
        XCTAssertThrowsError(try decode(w, size: 4)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testRecentDistanceBeforeAnyMatchIsCorrupt() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        w.recentDistance(0, lengthCode: 0)
        w.endOfFile()
        XCTAssertThrowsError(try decode(w, size: 4)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testEarlyEndOfFileIsCorrupt() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        w.endOfFile()
        XCTAssertThrowsError(try decode(w, size: 4)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testStreamRunningOutIsTruncated() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        XCTAssertThrowsError(try decode(w, size: 1000)) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    /// Reference §6.3.7: slot boundaries generated from the slots-per-extra
    /// counts, and the length table.
    func testStaticTablesMatchReference() {
        let slots = LZ29Tables.distanceSlots
        XCTAssertEqual(slots.count, 60)
        for slot in 0..<60 {
            let expected = RAR29StreamWriter.slot(slot)
            XCTAssertEqual(slots[slot].base, expected.base, "slot \(slot)")
            XCTAssertEqual(slots[slot].extraBits, expected.extra, "slot \(slot)")
        }
        XCTAssertEqual(slots[59].base + (1 << slots[59].extraBits), LZ29Tables.maxDistance)
        XCTAssertEqual(LZ29Tables.lengthBase, RAR29StreamWriter.lengthBase)
        XCTAssertEqual(LZ29Tables.lengthExtraBits, RAR29StreamWriter.lengthExtra)
        XCTAssertEqual(LZ29Tables.shortExtraBits, RAR29StreamWriter.shortExtra)
        XCTAssertEqual(LZ29Tables.totalCodeLengths, 404)
    }

    // MARK: - Through the public API

    func testCompressedEntryRoundTripsThroughArchive() throws {
        let text = Array("RAR 2.9 LZ / RAR 2.9 LZ / RAR 2.9 LZ".utf8)
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(text[0..<13])
        w.longMatch(length: text.count - 13, distance: 13)
        w.endOfFile()

        var builder = RAR3FixtureBuilder()
        builder.addCompressedFile(name: "lz.txt", packed: w.finished(), unpacked: Data(text))
        let archive = builder.build()
        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.first?.compressionMethod, 0x33)
        XCTAssertEqual(try RARArchive.extract(entry: entries[0], from: archive), Data(text))
    }

    /// The method byte is only the level; UNP_VER 15/20/26 select the older
    /// RAR 1.5 / 2.0 algorithms, which are not implemented.
    func testOlderAlgorithmVersionsAreRejected() throws {
        for version: UInt8 in [15, 20, 26] {
            var builder = RAR3FixtureBuilder()
            builder.addCompressedFile(name: "old.bin", packed: Data([0, 0, 0, 0]), unpacked: Data([1, 2, 3]))
            builder.files[0].unpackVersion = version
            let archive = builder.build()
            let entry = try RARArchive.entries(archive)[0]
            XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive)) {
                XCTAssertEqual($0 as? RARError, .unsupportedFeature(.compressionVersion(version)))
            }
        }
    }

    func testUnknownMethodIsRejected() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "x", text: "x")
        builder.files[0].method = 0x36
        let archive = builder.build()
        let entry = try RARArchive.entries(archive)[0]
        XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive)) {
            XCTAssertEqual($0 as? RARError, .unsupportedCompression(method: 0x36))
        }
    }

    func testCompressedCRCMismatchIsReported() throws {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("abc".utf8))
        w.endOfFile()
        var builder = RAR3FixtureBuilder()
        builder.addCompressedFile(name: "x", packed: w.finished(), unpacked: Data("abd".utf8))
        let archive = builder.build()
        let entry = try RARArchive.entries(archive)[0]
        XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive)) {
            XCTAssertEqual($0 as? RARError, .dataCRCMismatch)
        }
    }
}
