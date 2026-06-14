import XCTest
@testable import SwiftRAR

/// End-to-end tests that exercise the full public surface against a
/// fixture-built archive (signature detection, enumeration, extraction,
/// metadata propagation).
final class FixtureTests: XCTestCase {

    func testFullPipelineFromFixture() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "readme.txt", text: "fixture pipeline")
        builder.addStoredFile(name: "data.bin",   payload: Data((0..<256).map { UInt8($0) }))
        let archive = builder.build()

        // 1. Detection.
        guard let detection = RARSignature.detect(archive) else {
            return XCTFail("expected to detect classic RAR signature")
        }
        XCTAssertEqual(detection.format, .classic)
        XCTAssertEqual(detection.signatureOffset, 0)

        // 2. Enumeration.
        let entries = try RARArchive.entries(archive)
        XCTAssertEqual(entries.map { $0.name }, ["readme.txt", "data.bin"])
        XCTAssertTrue(entries.allSatisfy { $0.compressionMethod == 0x30 })
        XCTAssertTrue(entries.allSatisfy { !$0.isDirectory })

        // 3. Extraction.
        let first = try RARArchive.extract(entry: entries[0], from: archive)
        XCTAssertEqual(String(data: first, encoding: .utf8), "fixture pipeline")
        let second = try RARArchive.extract(entry: entries[1], from: archive)
        XCTAssertEqual(second, Data((0..<256).map { UInt8($0) }))
    }

    func testIsRARArchiveOnFixture() {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "a.txt", text: "x")
        XCTAssertTrue(RARArchive.isRARArchive(builder.build()))
    }
}
