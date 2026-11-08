# Getting Started

List a RAR archive and extract its entries safely.

## Overview

All work happens on an in-memory `Data` value; ``RARArchive`` has no state.

### Check and list an archive

```swift
import Foundation
import SwiftRAR

let data = try Data(contentsOf: archiveURL)
guard RARArchive.isRARArchive(data) else { return }

for entry in try RARArchive.entries(data) {
    print(entry.name, entry.unpackedSize, entry.isDirectory)
}
```

``RARArchive/isRARArchive(_:)`` only looks for a signature (also inside a
self-extracting executable). ``RARArchive/entries(_:)`` walks and verifies
every block header.

### Extract to disk without path traversal

```swift
let destination = URL(fileURLWithPath: "/tmp/unpacked", isDirectory: true)

for entry in try RARArchive.entries(data) {
    // `sanitizedPath` is nil for names that would escape `destination`.
    guard let path = entry.sanitizedPath, !entry.isSymbolicLink else { continue }
    let target = destination.appendingPathComponent(path)
    if entry.isDirectory {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        continue
    }
    // The declared size is archive-controlled: apply your own limit.
    guard entry.unpackedSize <= 512 * 1024 * 1024 else { continue }
    do {
        let bytes = try RARArchive.extract(entry: entry, from: data)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target)
    } catch RARError.unsupportedFeature(let feature) {
        print("skipped \(path): \(feature)")
    }
}
```

### Handle errors

Every failure is a ``RARError``:

- ``RARError/unsupportedFeature(_:)`` and
  ``RARError/unsupportedCompression(method:)`` — the archive is valid but uses
  something SwiftRAR does not implement (see ``RARFeature``).
- ``RARError/truncated``, ``RARError/malformedHeader``,
  ``RARError/headerCRCMismatch``, ``RARError/corruptData`` and
  ``RARError/dataCRCMismatch`` — the archive is damaged.
- ``RARError/notRAR`` — no RAR signature was found.
