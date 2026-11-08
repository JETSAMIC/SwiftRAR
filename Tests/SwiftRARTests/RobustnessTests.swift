import XCTest
@testable import SwiftRAR

/// "Throws or succeeds, never crashes or hangs" on damaged input.
final class RobustnessTests: XCTestCase {

    /// An archive with a stored and a compressed entry.
    private static func sampleArchive() -> Data {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("abcdefgh".utf8))
        w.longMatch(length: 24, distance: 8)
        w.shortMatch(1, extra: 3)
        w.recentDistance(0, lengthCode: 3)
        w.endOfFile()
        let packed = w.finished()
        let unpacked = try! LZ29Decoder.decode(packed, outputSize: 8 + 24 + 2 + 5)

        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "stored.txt", text: "stored payload")
        builder.addCompressedFile(name: "lz.bin", packed: packed, unpacked: unpacked)
        return builder.build()
    }

    private static func exercise(_ data: Data) {
        _ = RARArchive.isRARArchive(data)
        guard let entries = try? RARArchive.entries(data) else { return }
        for entry in entries {
            _ = try? RARArchive.extract(entry: entry, from: data)
            _ = entry.sanitizedPath
        }
    }

    func testSampleArchiveIsValid() throws {
        let data = Self.sampleArchive()
        let entries = try RARArchive.entries(data)
        XCTAssertEqual(entries.count, 2)
        for entry in entries {
            XCTAssertNoThrow(try RARArchive.extract(entry: entry, from: data))
        }
    }

    func testTruncationAtEveryOffset() {
        let data = Self.sampleArchive()
        for length in 0..<data.count {
            let prefix = data.prefix(length)
            Self.exercise(prefix)
            if length < data.count - 7 {
                // Cut inside an entry or header: listing must not silently
                // return every entry.
                if let entries = try? RARArchive.entries(prefix) {
                    XCTAssertLessThan(entries.count, 2, "length \(length)")
                }
            }
        }
    }

    func testSeededMutationFuzzOfArchive() {
        let original = Self.sampleArchive()
        var rng = SplitMix64(seed: 0x5241_5221)
        for _ in 0..<3_000 {
            var data = original
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let index = Int.random(in: 0..<data.count, using: &rng)
                data[index] = UInt8.random(in: 0...255, using: &rng)
            }
            Self.exercise(data)
        }
    }

    /// Header CRCs reject most archive mutations before the decoder runs,
    /// so fuzz the compressed stream directly as well.
    func testSeededMutationFuzzOfCompressedStream() {
        var w = RAR29StreamWriter()
        w.tables()
        w.literals(Array("the quick brown fox".utf8))
        w.longMatch(length: 40, distance: 19)
        w.shortMatch(2, extra: 5)
        w.recentDistance(1, lengthCode: 9, lengthExtra: 1)
        w.repeatLastMatch()
        w.newTablesFollow(keep: true)
        w.literals(Array("jumps".utf8))
        w.endOfFile()
        let original = w.finished()
        var rng = SplitMix64(seed: 42)
        for _ in 0..<3_000 {
            var stream = original
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let index = Int.random(in: 0..<stream.count, using: &rng)
                stream[index] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
            }
            if Bool.random(using: &rng) {
                stream = stream.prefix(Int.random(in: 0...stream.count, using: &rng))
            }
            _ = try? LZ29Decoder.decode(stream, outputSize: Int.random(in: 0...512, using: &rng))
        }
    }

    func testRandomBytesAfterSignature() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<1_000 {
            var data = Data(RARSignature.classicBytes)
            for _ in 0..<Int.random(in: 0...64, using: &rng) {
                data.append(UInt8.random(in: 0...255, using: &rng))
            }
            Self.exercise(data)
        }
    }

    func testHugeDeclaredSizesDoNotAllocate() throws {
        var builder = RAR3FixtureBuilder()
        var w = RAR29StreamWriter()
        w.tables()
        w.literal(1)
        w.endOfFile()
        builder.addCompressedFile(name: "bomb", packed: w.finished(), unpacked: Data([1]))
        builder.files[0].unpackedSize = 0xFFFF_FFFF
        let archive = builder.build()
        let entry = try RARArchive.entries(archive)[0]
        XCTAssertEqual(entry.unpackedSize, 0xFFFF_FFFF)
        XCTAssertThrowsError(try RARArchive.extract(entry: entry, from: archive))
    }
}
