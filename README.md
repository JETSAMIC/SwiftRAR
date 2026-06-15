# SwiftRAR

Pure-Swift decoder for STORE and LZSS-compressed RAR archives. No external dependencies, no patent-encumbered code.

## Status

**Alpha.** 47/47 unit tests passing. The decoder spine has been validated against synthetic fixtures (hand-crafted blocks, fuzzer-style corruption inputs, multi-entry archives). A real-world archive-corpus run — the kind that catches "this WinRAR build emits a non-standard extra field nobody documented" surprises — is still pending. Treat the API as provisional until that lands.

## What it does

- **Typed `RARError` surface** — `notRAR`, `truncated`, header/data CRC mismatches, `unsupportedCompression(method:)`, `unsupportedFeature(String)`, `entryOffsetOutOfRange`. Callers always get something they can route on.
- **Classic-RAR signature detection** — recognises the RAR 1.5 / 2.x / 3.x / 4.x marker block, with a 1 MiB SFX-stub scan window so self-extracting `.exe` wrappers don't defeat detection.
- **RAR5 signature detection** — the 8-byte RAR5 marker is recognised at the door, then refused with `unsupportedFeature("RAR5 block parsing")` so callers can fall back cleanly. RAR5 block parsing itself is not implemented.
- **RAR3 main-header parser** — `MAIN_HEAD (0x73)` with full main-flags decoding (volume, solid, password, lock, new numbering).
- **RAR3 file-header parser** — `FILE_HEAD (0x74)` including >4 GB high-word sizes, CP437/Latin-1 filename passthrough, DOS timestamps, attribute mask, method byte, and the stored CRC32.
- **RAR3 block-stream iterator** — walks every block, dispatches `MAIN`/`FILE`/`ENDARC`, skips `COMMENT`/`AV`/`SUB`/`PROTECT`/`SIGN`/`NEWSUB` auxiliaries, and guards against zero-advance corruption loops.
- **Bounds-checked little-endian `ByteReader`** — every header field read is range-checked; truncated input throws cleanly instead of trapping.
- **Public `RAREntry` value type** — name, packed/unpacked size, method byte, CRC32, host-OS byte, attributes, modification date, encrypted/solid/directory flags, and the byte offset of the entry's packed payload.
- **Public `RARArchive` API** — `entries(_:)`, `extract(entry:from:)`, `isRARArchive(_:)`. Stateless, static, takes and returns `Data`.
- **STORE extraction (method `0x30`)** — copies bytes from the archive `Data` with CRC32 verification and a strict offset guard.
- **CRC32 implementation** — IEEE 802.3, reflected polynomial `0xEDB88320`, lazy lookup table, `Data` fast path.
- **MSB-first `BitStream`** — 64-bit shift register with `peek` / `advance` / `readBits` / `alignToByte`; tail-zero on exhaustion so a malformed last symbol throws at the decoder layer instead of trapping.
- **Canonical Huffman decoder** — 15-bit code-length cap, over-subscription detection, empty-table sentinel.
- **RAR3 code-length pre-tree** — delta-XOR against the previous block plus the 16/17/18/19 RLE expansion symbols.
- **RAR3 LZSS tables** — length base/extra, distance base/extra (computed from `distanceBitLengthCounts`), short-match tables, low-distance alphabet.
- **RAR3 LZSS block driver (methods `0x31`–`0x35`)** — 4 MB sliding window, four-tree Huffman dispatch, recent-distance LRU, short-match path, long-match path with low-distance high/low split, repeat-last-match, keep-old-tables flag, end-of-block `1/00/01` protocol. All five method bytes share this driver; they differ only in encoder-side match-finder heuristics, so a single decoder serves the whole family.
- **Method-byte dispatch in `extract`** — routes `0x30` to the STORE extractor, `0x31`–`0x35` to the LZSS decoder, and rejects encrypted, solid, and unknown-method entries with typed errors.

## What it does NOT do

### Planned (deferred, with effort estimates)

- **RAR3 VM filter execution** (planned, ~1 week) — built-in filters (E8/E8E9 x86 call/jmp distance correction, RGB delta, audio delta, ARM jump) and the small custom-program VM. The filter-spec bytes are *already consumed* from the bitstream; only the execution engine is missing. Output passes through uncorrected, which is fine for un-filtered archives (the common case for text/document payloads) and wrong for filtered binaries.
- **Solid-mode dictionary inheritance** (planned, 2–3 days) — the sliding window must persist across `FILE_HEAD` boundaries within an archive marked solid. Currently each `extract` call instantiates a fresh window, so solid entries are refused with a typed error.
- **RAR5 base-header vint parsing + block walk** (planned, 1–2 weeks).
- **RAR5 LZSS-family decompressor** (planned, 2–3 weeks) — the `BitStream` and canonical-Huffman scaffolding transfers directly; the dictionary geometry, alphabet sizes, and filter set are what change.
- **RAR3 UTF-16-compressed filename decoding** (planned, 1–2 days) — `LHD_UNICODE` secondary stream. ASCII filenames work today; the compressed UTF-16 tail is currently dropped.
- **Multi-volume continuation** (planned, 3–5 days) — `.r00` / `.partNN.rar` stream concatenation plus split-before/split-after flag handling.
- **Header CRC16 verification** (planned, half a day) — `HEAD_CRC` is read but not validated. Pure correctness hardening.
- **AES-128 / AES-256 entry decryption** (planned, ~1 week) — RAR3 and RAR5 password-derived key schedules. Currently refused with `unsupportedFeature("encrypted entries")`.
- **Recovery records** (planned, 1–2 weeks) — `PROTECT_HEAD (0x78)` and the RAR5 recovery service block. Reed-Solomon over 512-byte sectors.

### Not planned

- **PPMd decompression** (Shkarin PPMII / PPMd-J1, RAR3 "best" mid-stream block). *Not planned — see [Reference/RAR-Format.md](Reference/RAR-Format.md) for the rationale.* PPMII is patent-encumbered; every shipping implementation inherits from Dmitry Shkarin's own source under terms incompatible with clean-room MIT/Apache redistribution. There is no specification independent of that source. PPMd-mode blocks are recognised inside the LZSS block header and rejected with `unsupportedFeature("RAR3 PPMd block ... requires PPMII port")`. That posture is permanent.
- **RAR compression / archive writing.** *Not planned — see [Reference/RAR-Format.md](Reference/RAR-Format.md) for the rationale.* The RAR format is closed-source on the writer side. `technote.txt` describes only the bitstream the decoder must consume, not the match-finder or entropy-coder choices the encoder makes. No open-source RAR compressor has ever shipped — not in `unrar` (decode-only by license), not in `libarchive`, not in `7-Zip`. Implementing one from public references is not possible; attempting it would be either a clean-room re-derivation of a closed format (legally hazardous) or fabrication. SwiftRAR is a **decoder library**, not a codec.
- **WinRAR AV-block (`0x76`) cryptographic verification.** *Not planned — see [Reference/RAR-Format.md](Reference/RAR-Format.md) for the rationale.* AV records use a WinRAR-proprietary signing scheme whose verification keys and algorithm details have never been published. The block structure parses fine; cryptographic verification is unreachable without the proprietary key material.

## SPM integration

Add SwiftRAR to your `Package.swift` dependencies:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YourApp",
    dependencies: [
        .package(url: "https://github.com/prestige-exe/SwiftRAR.git", branch: "main")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "SwiftRAR", package: "SwiftRAR")
            ]
        )
    ]
)
```

For local development against a working tree, use a path dependency instead:

```swift
.package(path: "../SwiftRAR")
```

Platform floors: iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1. Swift tools 6.0.

## Usage

```swift
import Foundation
import SwiftRAR

let archiveURL = URL(fileURLWithPath: "/path/to/example.rar")
let outputDirectory = URL(fileURLWithPath: "/tmp/unpacked")

do {
    let data = try Data(contentsOf: archiveURL)

    // Quick check before doing any real work.
    guard RARArchive.isRARArchive(data) else {
        print("Not a RAR archive.")
        return
    }

    // Enumerate every user-visible file/directory entry.
    let entries = try RARArchive.entries(data)

    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true
    )

    for entry in entries {
        if entry.isDirectory {
            let dirURL = outputDirectory.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true
            )
            continue
        }

        do {
            let payload = try RARArchive.extract(entry: entry, from: data)
            let fileURL = outputDirectory.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: fileURL)
            print("extracted: \(entry.name) (\(payload.count) bytes)")
        } catch RARError.unsupportedCompression(let method) {
            print("skip \(entry.name): compression method 0x\(String(method, radix: 16)) not implemented")
        } catch RARError.unsupportedFeature(let name) {
            print("skip \(entry.name): \(name) not implemented — hand off to The Unarchiver")
        } catch RARError.dataCRCMismatch {
            print("skip \(entry.name): CRC32 mismatch (archive corrupt)")
        }
    }
} catch RARError.notRAR {
    print("File is not a RAR archive.")
} catch RARError.truncated {
    print("Archive is truncated.")
} catch {
    print("Unexpected error: \(error)")
}
```

The public API is three static functions:

```swift
RARArchive.isRARArchive(_ data: Data) -> Bool
RARArchive.entries(_ data: Data) throws -> [RAREntry]
RARArchive.extract(entry: RAREntry, from data: Data) throws -> Data
```

`RAREntry` is a `Sendable`, `Equatable` value type — see `Sources/SwiftRAR/RAREntry.swift` for the full field list. Errors are `RARError` (also `Sendable` and `Equatable`); pattern-match on them to drive your UX.

## Supported variants

| Variant                          | Status | Notes                                                                 |
| -------------------------------- | :----: | --------------------------------------------------------------------- |
| RAR3 STORE (`0x30`)              |   OK   | Full extraction with CRC32 verification.                              |
| RAR3 LZSS (`0x31`–`0x35`)        |   OK   | Single decoder; methods differ only in encoder heuristics.            |
| RAR3 VM filters                  |   --   | Planned. Spec already consumed; execution engine missing.             |
| RAR3 solid mode                  |   --   | Planned. Refused with typed error today.                              |
| RAR3 PPMd ("best" block)         |   NO   | **Not planned** — Shkarin PPMII is patent-encumbered.                 |
| RAR3 encryption (AES-128)        |   --   | Planned. Refused with typed error today.                              |
| RAR3 multi-volume                |   --   | Planned. Refused with typed error today.                              |
| RAR5 signature detection         |   OK   | Recognised; enumeration refused with typed error.                     |
| RAR5 block parsing               |   --   | Planned (1–2 weeks).                                                  |
| RAR5 decompression               |   --   | Planned (2–3 weeks).                                                  |
| RAR5 encryption (AES-256)        |   --   | Planned.                                                              |
| Recovery records                 |   --   | Planned. Parsing only; repair is a stretch goal.                      |
| AV-block cryptographic verify    |   NO   | **Not planned** — proprietary signing scheme, no published keys.      |
| RAR compression / writing        |   NO   | **Not planned** — no public spec; closed-source encoder.              |

Legend: **OK** = shipping, **--** = planned, **NO** = not planned.

## Building from source

SwiftRAR is a plain Swift Package. Use the Xcode-beta toolchain (XCTest is provided by the matching Xcode):

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

Or open `Package.swift` in Xcode and use the standard test action. There is nothing else to install — no Homebrew dependencies, no `unrar` binary, no system frameworks beyond Foundation.

## Contributing

Issues and pull requests welcome. Two ground rules:

- **PPMd implementations are not accepted.** Shkarin's PPMII is patent-encumbered and every shipping implementation inherits from his source under terms that don't permit clean-room MIT/Apache redistribution. The `unsupportedFeature("RAR3 PPMd block ...")` error path is the permanent posture for that method. See [Reference/RAR-Format.md](Reference/RAR-Format.md) for the long-form rationale.
- **Compression / archive-writing implementations are not accepted.** The RAR format is closed on the writer side; no public spec exists for the encoder. A PR claiming to implement one is either copying from a non-permissive source or fabricating — neither is mergeable. See [Reference/RAR-Format.md](Reference/RAR-Format.md).

Inside those constraints: bug reports against the decoder, real-archive corpus failures, missing typed errors, and the planned-but-deferred items above are all fair game. When porting from public references, prefer the RAR `technote.txt` that shipped with WinRAR ≤ 4.x, the Kaitai Struct RAR spec (permissive), and `rarfile.py` (ISC). Do not copy from `unrar`, `libarchive`, or `7-Zip`.

## License

[MIT](LICENSE). See the `LICENSE` file for the full text.

## References

- [`Reference/RAR-Format.md`](Reference/RAR-Format.md) — the long-form format spec used to derive this implementation. Enumerates the full RAR landscape (RAR3 block types, RAR5 vint headers, every method byte including PPMd, filters, encryption, recovery records, AV blocks, the compressor's existence) and documents the legal/technical rationale for each "not planned" item.
