import Foundation
import XCTest
import SwiftRAR

/// Opt-in validation against real archives on the developer's machine.
///
/// Set `SWIFTRAR_CORPUS` to a colon-separated list of `.rar` files or
/// directories. Every entry SwiftRAR claims to support must extract with a
/// matching CRC32; entries that use unsupported features must fail with a
/// typed `RARError.unsupportedFeature` / `.unsupportedCompression`, never
/// with a CRC mismatch or a crash. Skipped when the variable is unset, so CI
/// does not depend on third-party files.
///
/// Optionally set `SWIFTRAR_CORPUS_REFERENCE` to a directory holding one
/// reference extraction per archive, made with an independent extractor
/// (for example `bsdtar -xf name.rar -C "$REF/name"`). Every extracted entry
/// is then compared byte for byte with `$REF/<archive name without .rar>/<path>`.
final class CorpusTests: XCTestCase {

    func testCorpusArchivesExtractOrFailCleanly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let spec = environment["SWIFTRAR_CORPUS"], !spec.isEmpty else {
            throw XCTSkip("SWIFTRAR_CORPUS not set")
        }
        let reference = environment["SWIFTRAR_CORPUS_REFERENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var files: [URL] = []
        for path in spec.split(separator: ":") {
            let url = URL(fileURLWithPath: String(path))
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let next = walker?.nextObject() as? URL {
                    if next.pathExtension.lowercased() == "rar" { files.append(next) }
                }
            } else {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty, "SWIFTRAR_CORPUS matched no .rar files")

        for file in files {
            let data = try Data(contentsOf: file)
            let entries: [RAREntry]
            do {
                entries = try RARArchive.entries(data)
            } catch let error as RARError {
                if case .unsupportedFeature = error { continue }
                XCTFail("\(file.lastPathComponent): enumeration failed: \(error)")
                continue
            }
            let referenceRoot = reference?.appendingPathComponent(
                file.deletingPathExtension().lastPathComponent, isDirectory: true)
            var extracted = 0
            var compared = 0
            if let root = referenceRoot {
                for entry in entries where entry.isDirectory {
                    guard let path = entry.sanitizedPath else { continue }
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(path).path, isDirectory: &isDir)
                    XCTAssertTrue(exists && isDir.boolValue, "\(file.lastPathComponent) › \(entry.name) is not a directory in the reference")
                }
            }
            for entry in entries where !entry.isDirectory {
                do {
                    let bytes = try RARArchive.extract(entry: entry, from: data)
                    XCTAssertEqual(UInt64(bytes.count), entry.unpackedSize, entry.name)
                    extracted += 1
                    if let root = referenceRoot, let path = entry.sanitizedPath {
                        let expected = try Data(contentsOf: root.appendingPathComponent(path))
                        XCTAssertEqual(bytes, expected, "\(file.lastPathComponent) › \(entry.name) differs from reference")
                        compared += 1
                    }
                } catch RARError.unsupportedFeature, RARError.unsupportedCompression {
                    continue
                } catch {
                    XCTFail("\(file.lastPathComponent) › \(entry.name): \(error)")
                }
            }
            let total = entries.filter { !$0.isDirectory }.count
            print("corpus: \(file.lastPathComponent): \(extracted)/\(total) entries extracted, \(compared) compared with reference")
        }
    }
}
