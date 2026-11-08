# SwiftRAR

Pure-Swift reader for RAR 1.5–4.x archives: list entries, extract stored and RAR 2.9-compressed files, with no dependencies.

## Requirements

- iOS 17, iPadOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1 or later (verified against the 27.x SDKs)
- Swift 6.0+ / Xcode 16+

## Installation

Add SwiftRAR to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/JETSAMIC/SwiftRAR.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [.product(name: "SwiftRAR", package: "SwiftRAR")]
    )
]
```

## Quick start

```swift
import Foundation
import SwiftRAR

let data = try Data(contentsOf: archiveURL)
let destination = URL(fileURLWithPath: "/tmp/unpacked", isDirectory: true)

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
```

The public API is three static functions on `RARArchive` — `isRARArchive(_:)`, `entries(_:)` and
`extract(entry:from:)` — plus the `RAREntry` value type and the `RARError` / `RARFeature` error types.
Full documentation is in the DocC catalog (`Sources/SwiftRAR/SwiftRAR.docc`).

## Format coverage

| Feature | Status | Notes |
| --- | --- | --- |
| RAR 1.5–4.x signature, SFX stub ≤ 1 MiB | Supported | |
| RAR 5.0+ signature (`Rar!\x1A\x07\x01\x00`) | Detected only | `entries` throws `.unsupportedFeature(.rar5Archive)` |
| RAR 1.4 (`RE~^`) | Unsupported | reported as `.notRAR` |
| Block walk: MAIN, FILE, ENDARC; skip COMMENT/AV/SUB/PROTECT/SIGN/NEWSUB/unknown | Supported | missing ENDARC tolerated |
| `HEAD_CRC` (low 16 bits of CRC-32) | Supported | verified on MAIN, FILE, NEWSUB and ENDARC blocks, including the RAR ≤ 2.x embedded-comment spans; legacy (0x75–0x79) and unknown blocks are skipped unchecked |
| > 4 GiB entries (`LHD_LARGE`) | Supported | extraction limited by memory (`.entryTooLarge` if not addressable) |
| File names: OEM, UTF-8, compact UTF-16 (`LHD_UNICODE`) | Supported | non-UTF-8 OEM names decoded as CP437 |
| MS-DOS timestamp | Supported | wall clock interpreted as UTC; invalid dates → `nil` |
| Extended time (`LHD_EXTTIME`) | Partial | mtime precision applied; ctime/atime/arctime ignored |
| Store (method `0x30`) | Supported | |
| RAR 2.9 LZ (methods `0x31`–`0x35`, `UNP_VER` 29/36) | Supported | non-solid, filter-free streams |
| RAR 1.5 / 2.0 LZ (`UNP_VER` 15/20/26) | Unsupported | `.unsupportedFeature(.compressionVersion(v))` |
| PPMd blocks | Unsupported | `.unsupportedFeature(.ppmd)` |
| RAR VM filters (E8, E8E9, delta, RGB, audio, Itanium, custom) | Unsupported | `.unsupportedFeature(.vmFilter)` |
| Solid archives | Partial | first entry extracts; continuation entries → `.solidEntry` |
| Multi-volume archives and split entries | Unsupported | `.unsupportedFeature(.multiVolume)` |
| Encrypted headers / entries | Unsupported | `.encryptedHeaders` / `.encryptedEntry` (entries still listed) |
| Entry CRC-32 | Supported | mismatch → `.dataCRCMismatch` |
| Recovery records, AV/signature verification, comments | Unsupported | blocks are skipped |
| RAR5 headers, compression, BLAKE2sp, AES-256 | Unsupported | |
| Creating / writing archives | Unsupported | out of scope |

## Safety

SwiftRAR is built to parse untrusted archives:

- every header is bounds-checked, header CRCs are verified, and all size arithmetic is overflow-checked (also on 32-bit watchOS);
- decompression never produces more than the entry's declared unpacked size, matches cannot reach before the
  start of the file, and a stream that runs out throws instead of looping;
- extracted data is always CRC-32 verified;
- malformed input throws a `RARError`; the test suite truncates archives at every byte offset and runs seeded
  mutation fuzzing of both archives and raw compressed streams.

Two things remain the caller's responsibility: entry **names** (use `RAREntry.sanitizedPath`, which rejects `..`
and strips absolute paths and drive letters) and **size limits** (the declared unpacked size is archive-controlled;
check `RAREntry.unpackedSize` before extracting). Symbolic-link entries (`isSymbolicLink`) carry an untrusted link
target as their content.

## Limitations

- Whole archives are processed in memory (`Data` in, `Data` out); there is no streaming API.
- Only the first entry of a solid archive and only filter-free RAR 2.9 streams can be decompressed. WinRAR applies
  the x86 (E8/E8E9) filter to executables by default and multimedia filters in some modes; such entries are
  rejected rather than extracted incorrectly.
- RAR 5.0 archives (WinRAR 5.0 and later default) are only detected.

## Validation

Besides the unit tests, `Tests/SwiftRARTests/CorpusTests.swift` validates against real archives when
`SWIFTRAR_CORPUS` lists `.rar` files or directories. With `SWIFTRAR_CORPUS_REFERENCE` it also compares every
extracted entry byte for byte with a reference extraction made by an independent tool:

```sh
mkdir -p ref/sample && bsdtar -xf corpus/sample.rar -C ref/sample
SWIFTRAR_CORPUS=corpus SWIFTRAR_CORPUS_REFERENCE=ref swift test --filter CorpusTests
```

The current implementation was validated this way against WinRAR 3.x archives (242 entries: 238 RAR 2.9 LZ
files, stored files, directories, EXT_TIME headers); every entry matched bsdtar's output. The corpus archives are
third-party files and are not part of the repository.

## Contributing

Issues and pull requests are welcome — especially real-world archives that fail. Two ground rules:

- PPMd decoding and archive creation/compression are out of scope and will not be merged.
- SwiftRAR is a clean-room implementation. Contributions must be written from public format documentation and
  black-box testing only — never from, or while consulting, the source code of `unrar`, 7-Zip, libarchive or any
  other RAR implementation.

## References

- [`Reference/RAR-Format.md`](Reference/RAR-Format.md) — the format specification this implementation follows,
  including errata and an implementation-status table.
- RAR `technote.txt` (Eugene Roshal / RARLAB, shipped with RAR/WinRAR up to 4.x) — block and header layout.
- "RAR 5.0 archive format" (RARLAB, rarlab.com/technote.htm) — RAR 5.0 container.
- RFC 1951 (L. Peter Deutsch) — canonical prefix-code construction.

## Provenance & license

SwiftRAR is an original, clean-room implementation. Its specification (`Reference/RAR-Format.md`) was written from
RARLAB's published format documentation and other public descriptions, and the implementation was written from
that specification and validated only by black-box comparison of extracted output with an independent extractor.
No source code from `unrar`, 7-Zip, libarchive or any other RAR implementation was used, consulted or adapted.

RAR is an archive format designed by Eugene Roshal; RAR and WinRAR are trademarks of RARLAB (win.rar GmbH).
SwiftRAR is not affiliated with RARLAB and only decompresses: it cannot create RAR archives.

SwiftRAR is released under the [MIT License](LICENSE) © 2026 Christian Vozar.
