# ``SwiftRAR``

List and extract RAR 1.5–4.x archives in pure Swift.

## Overview

SwiftRAR reads classic RAR archives (signature `Rar!\x1A\x07\x00`, written by
RAR/WinRAR 1.5 through 4.x) from an in-memory `Data` value. It lists every
entry and extracts stored entries and entries compressed with the RAR 2.9
algorithm used by RAR/WinRAR 3.x and 4.x. Every header is bounds-checked,
the header CRC of every block SwiftRAR interprets is verified, and every
extracted entry is CRC-32 verified.

RAR 5.0 archives are recognised but not parsed. Encryption, multi-volume
sets, solid continuation entries, PPMd, RAR VM filters and the older RAR 1.5
and 2.0 compression algorithms are reported as
``RARError/unsupportedFeature(_:)`` with a ``RARFeature`` describing what is
missing, so you can route those archives to another tool.

> Important: Entry names come from the archive and are untrusted. Use
> ``RAREntry/sanitizedPath`` — never ``RAREntry/name`` — to build file-system
> paths.

SwiftRAR is an independent, clean-room implementation written from public
format documentation (see `Reference/RAR-Format.md` in the repository) and
released under the MIT license. RAR is a format and trademark of RARLAB;
SwiftRAR only reads archives.

## Topics

### Essentials

- <doc:GettingStarted>
- ``RARArchive``
- ``RAREntry``

### Errors

- ``RARError``
- ``RARFeature``

### Format detection

- ``RARSignature``
- ``RARSignature/Detection``
- ``RARFormat``

### Package information

- ``SwiftRAR/SwiftRAR``
