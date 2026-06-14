# SwiftRAR

Native Swift reader for RAR archives. Foundation-only, no C shims, no
bundled UnRAR source.

SwiftRAR is part of the `prestige-exe` family of small, focused archive /
format packages alongside [SwiftPCX](https://github.com/prestige-exe/SwiftPCX).
It targets the same broad platform matrix (iOS 17+, macOS 14+, tvOS 17+,
watchOS 10+, visionOS 1+), Swift 6 strict-concurrency clean, MIT licensed.

## What it does today

- Detect RAR archive signatures across every released version:
  - RAR 1.5 / 2.x / 3.x / 4.x (classic, 7-byte signature).
  - RAR 5.0+ (8-byte signature).
  - Self-extracting (SFX) archives with up to 1 MiB of executable stub
    prepended.
- Parse RAR3 archive structure: `MAIN_HEAD` plus per-file `FILE_HEAD`
  blocks, skipping auxiliary block types (comments, AV records, recovery,
  signatures, subblocks).
- Enumerate every file/directory entry as a `RAREntry` carrying name,
  packed/unpacked sizes, CRC32, host OS, attributes, modification date,
  and the offset of the packed bytes within the source `Data`.
- Extract STORE-method entries (`compressionMethod == 0x30`) and verify
  their CRC32 against the value stored in the file header.

## What it does *not* do (yet)

- Decompress RAR3 methods `0x31`-`0x35` (LZSS + Huffman, multimedia
  filters, PPMd "best" method).
- Parse or decompress RAR5 archives (signature is detected; `entries`
  currently throws `RARError.unsupportedFeature("RAR5 block parsing")`).
- Multi-volume archives, header / payload encryption, solid mode,
  recovery record verification.
- Archive creation — and it never will: producing RAR archives without
  Alexander Roshal's permission is contractually forbidden, regardless
  of how the algorithm was obtained.

See [`Sources/SwiftRAR/Decompression/RAR3LZSSDecoder.swift`](Sources/SwiftRAR/Decompression/RAR3LZSSDecoder.swift)
for the full deferral rationale, time estimates, and licensing notes.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/prestige-exe/SwiftRAR", from: "0.1.0")
```

Then add `"SwiftRAR"` to your target's dependency list.

## Usage

```swift
import SwiftRAR

let archive: Data = try Data(contentsOf: archiveURL)

// 1. Quick check.
guard RARArchive.isRARArchive(archive) else {
    throw MyError.notARAR
}

// 2. Enumerate.
let entries = try RARArchive.entries(archive)
for entry in entries {
    print("\(entry.name) — \(entry.unpackedSize) bytes, method 0x\(String(entry.compressionMethod, radix: 16))")
}

// 3. Extract the STORE entries.
for entry in entries where entry.compressionMethod == 0x30 {
    do {
        let bytes = try RARArchive.extract(entry: entry, from: archive)
        try bytes.write(to: outputDirectory.appendingPathComponent(entry.name))
    } catch RARError.unsupportedCompression(let method) {
        print("Skipping \(entry.name): method 0x\(String(method, radix: 16)) not yet supported")
    }
}
```

### Integration pattern: probe-before-download

For a downloader that should refuse archives SwiftRAR cannot fully extract:

```swift
let entries = try RARArchive.entries(headBytes)
let unsupported = entries.filter { $0.compressionMethod != 0x30 }
if !unsupported.isEmpty {
    throw ImportError.rarRequiresExternalTool(entries: unsupported.map(\.name))
}
```

## Errors

`RARError` is the single error type thrown by the package:

| Case | When it fires |
| --- | --- |
| `.notRAR` | The data doesn't contain a recognised signature in the first 1 MiB. |
| `.unsupportedVersion` | Signature recognised but version byte is unknown. |
| `.truncated` | A header or payload walks past `data.endIndex`. |
| `.headerCRCMismatch` | Reserved for the future header-CRC verifier. |
| `.dataCRCMismatch` | Extracted bytes don't match the file-header CRC. |
| `.unsupportedCompression(method:)` | Caller asked to extract a non-STORE entry. |
| `.unsupportedFeature(String)` | Encryption, multi-volume, RAR5 block parsing, etc. |
| `.entryOffsetOutOfRange` | Caller passed a `Data` that doesn't match the entry's source. |

## Licensing

SwiftRAR is MIT-licensed. The package does **not** include or derive from
the official UnRAR source from rarlab.com (whose license is non-OSI and
incompatible with MIT redistribution). Format parsing is implemented
strictly from public specifications:

- [RAR 5.0 TechNote](https://www.rarlab.com/technote.htm) — official
  RARLAB documentation, freely redistributable as a format spec.
- [Kaitai Struct RAR grammar](https://formats.kaitai.io/rar/) — MIT.
- [Wikipedia: RAR (file format)](https://en.wikipedia.org/wiki/RAR_\(file_format\))
  for version history and signature layouts.
- [rarfile (Python)](https://github.com/markokr/rarfile) and
  [unrar.js (bitjs)](https://github.com/codedread/bitjs) as clean-room
  references for block enumeration logic.

When the deferred compressed methods land, PPMd (Dmitry Shkarin's
public-domain PPMII model) will be re-implemented from canonical PPMd
sources with the required attribution. Until then, callers needing
compressed RAR extraction should pair SwiftRAR with an external tool
(`The Unarchiver`, `unar`, libarchive) or skip the archives.

## Building

```sh
swift build
swift test
```

Requires Swift 6.0+. CI / local development uses Xcode 26 beta against
the latest tvOS / iOS SDKs but the package only depends on Foundation
and XCTest.
