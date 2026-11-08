import Foundation
import XCTest
import SwiftRAR

/// Compiles and runs the README / GettingStarted quick-start code verbatim
/// (only `archiveURL` and the destination are provided by the test).
final class QuickStartTests: XCTestCase {

    func testReadmeQuickStart() throws {
        var builder = RAR3FixtureBuilder()
        builder.addStoredFile(name: "docs/readme.txt", text: "hello")
        builder.addStoredFile(name: "../escape.txt", text: "nope")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftRAR-QuickStart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archiveURL = scratch.appendingPathComponent("test.rar")
        try builder.build().write(to: archiveURL)

        // --- README quick start ---
        let data = try Data(contentsOf: archiveURL)
        let destination = scratch.appendingPathComponent("unpacked", isDirectory: true)

        for entry in try RARArchive.entries(data) {
            // Never use `entry.name` as a path: it is untrusted and may contain "../".
            guard let path = entry.sanitizedPath, !entry.isSymbolicLink else { continue }
            let target = destination.appendingPathComponent(path)

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            do {
                let bytes = try RARArchive.extract(entry: entry, from: data)  // CRC-32 verified
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target)
            } catch RARError.unsupportedFeature(let feature) {
                print("skipped \(path): \(feature)")   // e.g. encrypted, solid, PPMd
            }
        }
        // --- end ---

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("docs/readme.txt"), encoding: .utf8),
            "hello"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escape.txt").path))
    }
}
