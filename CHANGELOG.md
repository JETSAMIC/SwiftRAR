# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased (proposed initial release)

### Added
- `RARArchive.entries(_:)`, `extract(entry:from:)` and `isRARArchive(_:)` for RAR 1.5–4.x archives
  in memory, including self-extracting archives with stubs up to 1 MiB.
- Extraction of stored entries and of RAR 2.9 LZ-compressed entries (methods `0x31`–`0x35`,
  `UNP_VER` 29/36), CRC-32 verified; validated byte for byte against an independent extractor on
  real WinRAR 3.x archives.
- `HEAD_CRC` verification of main, file, service and end blocks, including the RAR ≤ 2.x
  embedded-comment spans.
- File-name decoding for OEM (UTF-8 or CP437), UTF-8 and compact UTF-16 names; `\` separators
  normalised for DOS-family hosts.
- DOS timestamp decoding with range validation and EXT_TIME sub-second mtime.
- `RAREntry.sanitizedPath` (path-traversal-safe relative path) and `RAREntry.isSymbolicLink`.
- Typed errors: `RARError` with `RARFeature` describing unsupported features (RAR5, multi-volume,
  encryption, solid continuation, PPMd, VM filters, RAR 1.5/2.0 compression).
- `Reference/RAR-Format.md`: specification of the RAR 1.5–4.x and RAR 5.0 containers, the RAR 2.9
  LZ bitstream and the checksums, with errata and implementation status.
- DocC catalog, opt-in real-archive corpus test (with optional byte-for-byte comparison against a
  reference extraction), truncation and seeded fuzz tests.

### Notes
- SwiftRAR is a clean-room implementation written from public format documentation and black-box
  testing, released under the MIT license. It contains no code derived from `unrar` or other RAR
  implementations. Split entries of multi-volume sets are rejected with
  `RARFeature.multiVolume`.

### Security
- Hardened against hostile archives: checked arithmetic (including 32-bit watchOS), output capped
  at the declared size, LZ matches confined to produced output, bounded loops on truncated or
  corrupt streams.
