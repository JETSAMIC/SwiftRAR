import XCTest
@testable import SwiftRAR

final class StoreTests: XCTestCase {

    func testRoundTripSingleStoredFile() throws {
        let original = Data("The five boxing wizards jump quickly.".utf8)
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "pangram.txt", payload: original)
        let archive = builder.build()

        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        XCTAssertEqual(entry.name, "pangram.txt")
        XCTAssertEqual(entry.unpackedSize, UInt64(original.count))
        XCTAssertEqual(entry.compressionMethod, 0x30)
        XCTAssertFalse(entry.isDirectory)
        XCTAssertFalse(entry.isEncrypted)
        XCTAssertFalse(entry.isSolid)

        let extracted = try RARArchive.extract(entry: entry, from: archive)
        XCTAssertEqual(extracted, original)
    }

    func testRoundTripMultipleStoredFiles() throws {
        var builder = RAR3FixtureBuilder()
        let files: [(String, String)] = [
            ("first.txt", "first body"),
            ("second.txt", "the second file is longer than the first one for variety"),
            ("third.bin", String(repeating: "X", count: 1024))
        ]
        for (name, body) in files {
            builder.addStoredFile(name: name, text: body)
        }
        let archive = builder.build()
        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.count, files.count)
        for (entry, (name, body)) in zip(entries, files) {
            XCTAssertEqual(entry.name, name)
            let extracted = try RARArchive.extract(entry: entry, from: archive)
            XCTAssertEqual(extracted, Data(body.utf8))
        }
    }

    func testEmptyFileRoundTrips() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "empty.txt", payload: Data())
        let archive = builder.build()
        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.count, 1)
        let extracted = try RARArchive.extract(entry: entries[0], from: archive)
        XCTAssertEqual(extracted, Data())
    }

    func testExtractDetectsCorruptedPayload() throws {
        let original = Data("integrity check".utf8)
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "x.txt", payload: original)
        var archive = builder.build()

        let entries = try RARArchive.entries(archive)
        // Tamper with the last byte of the payload (which is at the very
        // end of the archive minus the 7-byte ENDARC_HEAD).
        let endarcSize = 7
        let payloadEnd = archive.count - endarcSize
        archive[payloadEnd - 1] ^= 0xFF

        XCTAssertThrowsError(try RARArchive.extract(entry: entries[0], from: archive)) { err in
            XCTAssertEqual(err as? RARError, .dataCRCMismatch)
        }
    }

    func testExtractRejectsCompressedEntry() {
        // Synthesise an entry that claims compression method 0x33; ensure
        // the public extract throws unsupportedCompression without ever
        // touching the bytes.
        let entry = RAREntry(
            name: "fake.bin",
            unpackedSize: 100,
            packedSize: 100,
            compressionMethod: 0x33,
            unpackVersion: 29,
            crc32: 0,
            hostOS: 2,
            attributes: 0,
            modificationDate: nil,
            isDirectory: false,
            isEncrypted: false,
            isSolid: false,
            dataOffset: 0
        )
        XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: Data(count: 100))) { err in
            guard case .unsupportedCompression(let m)? = err as? RARError else {
                XCTFail("expected unsupportedCompression, got \(err)")
                return
            }
            XCTAssertEqual(m, 0x33)
        }
    }

    func testEntriesOnNonRARDataThrowsNotRAR() {
        XCTAssertThrowsError(try RARArchive.entries(Data("nope".utf8))) { err in
            XCTAssertEqual(err as? RARError, .notRAR)
        }
    }

    func testEntriesOnRAR5DataThrowsUnsupportedFeature() {
        var data = Data(RARSignature.rar5Bytes)
        // Fake some trailing bytes to look archive-like.
        data.append(Data(repeating: 0x00, count: 32))
        XCTAssertThrowsError(try RARArchive.entries(data)) { err in
            if case .unsupportedFeature? = err as? RARError {
                return
            }
            XCTFail("expected unsupportedFeature, got \(err)")
        }
    }

    func testExtractRejectsMismatchedArchiveData() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "real.txt", text: "real bytes")
        let archive = builder.build()
        let entries = try RARArchive.entries(archive)

        // Try extracting from a shorter, unrelated Data — the dataOffset
        // walks off the end.
        let bogus = Data(repeating: 0xAA, count: 4)
        XCTAssertThrowsError(try RARArchive.extract(entry: entries[0], from: bogus)) { err in
            XCTAssertEqual(err as? RARError, .entryOffsetOutOfRange)
        }
    }
}
