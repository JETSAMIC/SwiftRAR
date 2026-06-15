# The RAR Archive Format

A reference document covering the on-disk layout, header structures, compression
methods, and ancillary mechanics of the RAR archive format from RAR 1.5 through
RAR 5. The audience is implementers of decoders and tooling that needs to
inspect or extract RAR archives. The intent is to be sober and accurate about
what the format actually contains, what is publicly documented, and what is
not.

This document also closes with a precise statement of SwiftRAR's implementation
scope: what is implemented, what is deferred (but reachable from public specs),
and what is permanently out of scope (because the algorithm is patent-encumbered,
the keys are proprietary, or no public specification exists at all).

---

## 1. History and scope

### 1.1 Origins

RAR ("Roshal Archive") was created by Eugene Roshal in 1993 and is maintained
by him and his brother Alexander Roshal under the win.rar GmbH umbrella, which
licenses WinRAR — the canonical encoder — for Windows and ports a command-line
tool (`rar`) for several Unix-like platforms. From the beginning, the format
has had two characters: WinRAR (the encoder) is closed-source, proprietary, and
commercial; `unrar` (the decoder) ships as source under a license that permits
inspection and compilation but explicitly forbids re-using its code to build
a RAR-compatible compressor. This split — proprietary encoder, source-available
decoder — has shaped every open-source RAR implementation.

The format has four major on-disk generations:

| Era         | Years        | Marker bytes                                    | Notes                                                                 |
|-------------|--------------|-------------------------------------------------|-----------------------------------------------------------------------|
| RAR 1.x     | 1993–1994    | (early — pre-`Rar!` magic)                      | LZ77-family with small windows. Rare in the wild today.               |
| RAR 2.x     | 1996–2002    | `Rar!\x1a\x07\x00` (7 bytes)                    | Adds multimedia compression, AV records, recovery records.            |
| RAR 3.x/4.x | 2002–2013    | `Rar!\x1a\x07\x00` (7 bytes)                    | New LZSS engine, four-tree dynamic Huffman, PPMd, VM filters, AES-128.|
| RAR 5.x     | 2013–present | `Rar!\x1a\x07\x01\x00` (8 bytes)                | New header framing (vint sizes, BLAKE2 hashing, AES-256, 1 GB window).|

This document calls the third generation "RAR3" throughout. WinRAR 4.x continued
to ship the same on-disk format with minor extensions, so RAR3 and RAR4
archives are read by the same parser; the distinction matters only when
recording which WinRAR version wrote the file.

### 1.2 Why the format exists

RAR was designed in a world where ZIP existed but its compression (deflate)
left ratio on the table for large or text-heavy data. Roshal's contribution
was a careful LZSS implementation with a much larger sliding window (1 MB in
RAR 2.x, 4 MB in RAR3, up to 1 GB in RAR5), a four-tree dynamic Huffman
arrangement, an arithmetic-coded PPMd path for high-redundancy inputs, and
a small bytecode-driven VM for content-aware filters (E8/E8E9 x86 call-offset
correction, RGB delta, audio delta, ARM branch fixup). The result is a format
that beats deflate on most realistic inputs and competes with bzip2 and 7z LZMA
without LZMA's memory cost.

The format also picked up archive-level features that ZIP added piecemeal:
multi-volume splitting with named parts (`.r00`, `.r01`, … and later
`.part01.rar`), per-entry encryption (AES-128 in RAR3, AES-256 in RAR5),
optional header encryption, optional recovery records (a Reed-Solomon overlay
for surviving sector-level damage), and solid-mode compression where the
sliding window is shared across multiple entries in the archive.

### 1.3 On-disk shape at a glance

A RAR archive is a flat byte stream consisting of:

1. An optional SFX (self-extracting) stub at the front — an executable that
   knows how to find the RAR signature inside itself and extract from there.
   Common in the wild on Windows. Decoders must scan for the signature, not
   assume it is at offset 0.
2. The signature bytes — `Rar!\x1a\x07\x00` (RAR3) or `Rar!\x1a\x07\x01\x00`
   (RAR5).
3. A sequence of blocks. Each block has a small header (its CRC, type, flags,
   size, optional add-size for blocks that carry data) followed optionally by
   a data payload.
4. The first non-stub block is always the main archive header (MAIN_HEAD in
   RAR3, type-1 main record in RAR5).
5. File headers (FILE_HEAD in RAR3, type-2 file record in RAR5) are
   interleaved with their compressed data payloads.
6. The archive ends at an end-of-archive marker (ENDARC_HEAD in RAR3,
   type-5 end record in RAR5), or at EOF if the writer omitted the marker
   (rare but legal in RAR3).

There is no central directory the way ZIP has one. To enumerate entries a
decoder must walk the block stream from the signature forward. This is by
design: it lets RAR be appended to (volumes, recovery records, comments) and
still parsed.

---

## 2. RAR3 file structure

### 2.1 Signature

The seven-byte signature is:

```
Offset  Hex                  ASCII
0x00    52 61 72 21          R a r !
0x04    1A 07 00             . . .
```

`0x1A` is the DOS end-of-file character (a holdover so `TYPE archive.rar` on
DOS would stop printing at the signature); `0x07` is the bell control character;
`0x00` is the version-major byte distinguishing RAR3 (0x00) from RAR5 (0x01).

When extracting a self-extracting archive, the decoder scans the first 1 MiB
of the input for this 7-byte sequence. If found at any offset, the archive
proper begins at that offset; everything before it is the SFX stub and is
discarded. If not found in the first 1 MiB the file is not a RAR archive.

### 2.2 Generic block header

Every RAR3 block, including the main archive header, file headers, sub-blocks,
comment blocks, and the end marker, begins with the same seven-byte preamble:

| Offset | Size | Field         | Meaning                                                         |
|--------|------|---------------|-----------------------------------------------------------------|
| 0      | 2    | HEAD_CRC      | CRC-16/IBM of all subsequent bytes of this block's header.       |
| 2      | 1    | HEAD_TYPE     | Block type (0x72 marker, 0x73 main, 0x74 file, 0x75 comment, …) |
| 3      | 2    | HEAD_FLAGS    | Type-specific flag bits (little-endian).                         |
| 5      | 2    | HEAD_SIZE     | Size in bytes of this block's header (little-endian).            |

If `HEAD_FLAGS & 0x8000` is set, two additional fields follow before the
type-specific header body:

| Offset | Size | Field         | Meaning                                                         |
|--------|------|---------------|-----------------------------------------------------------------|
| 7      | 4    | ADD_SIZE      | Size in bytes of the data payload that follows the header.       |

Blocks with `LHD_LARGE` (0x0100) set on a FILE_HEAD additionally have high
words for PACK_SIZE and UNP_SIZE — see §2.4 below.

All integers are little-endian unless explicitly noted.

### 2.3 Block types

| HEAD_TYPE | Name           | Meaning                                                                 |
|-----------|----------------|-------------------------------------------------------------------------|
| 0x72      | MARK_HEAD      | The signature itself, treated as a degenerate block.                    |
| 0x73      | MAIN_HEAD      | Main archive header. Exactly one, immediately after the signature.      |
| 0x74      | FILE_HEAD      | File header. One per entry.                                             |
| 0x75      | COMMENT_HEAD   | Archive comment (legacy; RAR ≥ 3.0 embeds comments in main/file flags). |
| 0x76      | AV_HEAD        | Authenticity verification record (WinRAR-proprietary signing).          |
| 0x77      | SUB_HEAD       | Old-style sub-block (largely superseded by NEWSUB).                     |
| 0x78      | PROTECT_HEAD   | Recovery record (Reed-Solomon over 512-byte sectors).                   |
| 0x79      | SIGN_HEAD      | Signature record (legacy).                                              |
| 0x7A      | NEWSUB_HEAD    | New-style sub-block (carries metadata: extended timestamps, ACLs, etc.) |
| 0x7B      | ENDARC_HEAD    | End-of-archive marker.                                                  |

A decoder must accept and skip every type it does not consume — auxiliary
blocks like COMMENT_HEAD, AV_HEAD, SUB_HEAD, PROTECT_HEAD, SIGN_HEAD, and
NEWSUB_HEAD are common enough that refusing them is incorrect, but consuming
their semantics is optional for a basic extractor.

### 2.4 MAIN_HEAD (0x73)

The main archive header sits immediately after the signature and carries
archive-wide flags.

| Offset | Size | Field            | Meaning                                                              |
|--------|------|------------------|----------------------------------------------------------------------|
| 0      | 7    | (generic header) | HEAD_CRC, HEAD_TYPE=0x73, HEAD_FLAGS, HEAD_SIZE.                     |
| 7      | 2    | HIGH_POS_AV      | Position of AV block (legacy; usually zero).                          |
| 9      | 4    | POS_AV           | Position of AV block (legacy; usually zero).                          |

`HEAD_FLAGS` for MAIN_HEAD:

| Bit    | Mask    | Name           | Meaning                                                              |
|--------|---------|----------------|----------------------------------------------------------------------|
| 0      | 0x0001  | MHD_VOLUME     | Archive is one volume of a multi-volume set.                          |
| 1      | 0x0002  | MHD_COMMENT    | Old-style archive comment is present (deprecated).                    |
| 2      | 0x0004  | MHD_LOCK       | Archive is locked (no further modification by WinRAR).                |
| 3      | 0x0008  | MHD_SOLID      | Archive uses solid-mode compression (shared dictionary across files). |
| 4      | 0x0010  | MHD_NEWNUMBERING | Multi-volume naming uses `.partNN.rar` (otherwise `.r00`, `.r01`).  |
| 5      | 0x0020  | MHD_AV         | Authenticity verification information is present.                     |
| 6      | 0x0040  | MHD_PROTECT    | Recovery record is present.                                           |
| 7      | 0x0080  | MHD_PASSWORD   | Block headers themselves are encrypted with a password.               |
| 8      | 0x0100  | MHD_FIRSTVOLUME| This volume is the first in a multi-volume set (RAR ≥ 3.0).           |

A decoder that aims for an honest scope will reject MHD_VOLUME (without
volume-continuation support), MHD_PASSWORD (without header encryption support),
and report MHD_SOLID as an archive-level capability that downstream FILE_HEAD
processing must honor.

### 2.5 FILE_HEAD (0x74)

The file header describes one archive entry. It is immediately followed by
PACK_SIZE bytes of compressed (or stored) data, after which the next block
header begins.

| Offset | Size | Field            | Meaning                                                              |
|--------|------|------------------|----------------------------------------------------------------------|
| 0      | 7    | (generic header) | HEAD_CRC, HEAD_TYPE=0x74, HEAD_FLAGS, HEAD_SIZE.                     |
| 7      | 4    | PACK_SIZE        | Low 32 bits of compressed payload size.                              |
| 11     | 4    | UNP_SIZE         | Low 32 bits of uncompressed size.                                    |
| 15     | 1    | HOST_OS          | 0=MS-DOS, 1=OS/2, 2=Win32, 3=Unix, 4=Mac OS, 5=BeOS.                 |
| 16     | 4    | FILE_CRC         | CRC-32 of the uncompressed data (IEEE 802.3, polynomial 0xEDB88320). |
| 20     | 4    | FTIME            | Last-modified time in MS-DOS packed format.                          |
| 24     | 1    | UNP_VER          | Minimum unpacker version × 10 (0x1D = 2.9, 0x24 = 3.6).               |
| 25     | 1    | METHOD           | Compression method (0x30..0x35, see §4).                             |
| 26     | 2    | NAME_SIZE        | Length in bytes of the filename field.                                |
| 28     | 4    | ATTR             | Host-OS file attributes.                                              |
| 32     | 4    | HIGH_PACK_SIZE   | (Optional, LHD_LARGE) High 32 bits of compressed size.                |
| 36     | 4    | HIGH_UNP_SIZE    | (Optional, LHD_LARGE) High 32 bits of uncompressed size.              |
| …      | N    | FILE_NAME        | NAME_SIZE bytes; CP437/Latin-1, optionally followed by UTF-16 tail.   |
| …      | 8    | SALT             | (Optional, LHD_SALT) Random salt for encrypted entries.               |
| …      | 7    | EXT_TIME         | (Optional, LHD_EXTTIME) Extended (nanosecond) timestamps.             |

`HEAD_FLAGS` for FILE_HEAD:

| Bit    | Mask    | Name              | Meaning                                                          |
|--------|---------|-------------------|------------------------------------------------------------------|
| 0      | 0x0001  | LHD_SPLIT_BEFORE  | This entry's data continues from the previous volume.            |
| 1      | 0x0002  | LHD_SPLIT_AFTER   | This entry's data continues into the next volume.                |
| 2      | 0x0004  | LHD_PASSWORD      | Entry is encrypted.                                              |
| 3      | 0x0008  | LHD_COMMENT       | Old-style comment is present.                                    |
| 4      | 0x0010  | LHD_SOLID         | Entry is part of a solid stream.                                 |
| 5..7   | 0x00E0  | LHD_WINDOW_MASK   | Dictionary size: 0=64K, 1=128K, 2=256K, 3=512K, 4=1M, 5=2M, 6=4M, 7=directory entry. |
| 8      | 0x0100  | LHD_LARGE         | HIGH_PACK_SIZE and HIGH_UNP_SIZE are present (entries > 4 GB).    |
| 9      | 0x0200  | LHD_UNICODE       | FILE_NAME is followed by a compressed UTF-16 representation.     |
| 10     | 0x0400  | LHD_SALT          | SALT field is present (encrypted-entries salt for AES-128 KDF).  |
| 11     | 0x0800  | LHD_VERSION       | Entry is a stored version (multiple-version archive).            |
| 12     | 0x1000  | LHD_EXTTIME       | EXT_TIME field is present.                                       |
| 13     | 0x2000  | LHD_EXTFLAGS      | Reserved.                                                        |

LHD_WINDOW_MASK = 0xE0 (all three bits set, value 7) means the entry is a
directory, not a file. The compressed data size in that case is zero.

#### 2.5.1 DOS timestamp encoding

`FTIME` is a 32-bit MS-DOS packed timestamp:

```
bits 31..25 = year - 1980   (0..127, so 1980..2107)
bits 24..21 = month         (1..12)
bits 20..16 = day           (1..31)
bits 15..11 = hour          (0..23)
bits 10..5  = minute        (0..59)
bits 4..0   = second / 2    (0..29, even seconds only)
```

If LHD_EXTTIME is set, a 7-byte block follows the filename giving
microsecond-precision mtime/ctime/atime/arctime with a small variable layout
described in technote.txt §1.5.

#### 2.5.2 Filename encoding

`FILE_NAME` is `NAME_SIZE` bytes. If `LHD_UNICODE` is not set the bytes are
the filename in CP437 (or Latin-1, depending on the writing platform — the
distinction is not recorded in the header). If `LHD_UNICODE` is set the
NAME_SIZE-byte field contains the ASCII filename, a single zero byte
terminator, then a compressed UTF-16LE representation using a small
nibble-stream RLE scheme documented in technote.txt §1.6.

### 2.6 ENDARC_HEAD (0x7B)

The end-of-archive marker.

| Offset | Size | Field            | Meaning                                                              |
|--------|------|------------------|----------------------------------------------------------------------|
| 0      | 7    | (generic header) | HEAD_CRC, HEAD_TYPE=0x7B, HEAD_FLAGS, HEAD_SIZE.                     |
| 7      | 4    | ARC_DATA_CRC     | (Optional, EARC_DATACRC) Volume-wide CRC for the data so far.        |
| 11     | 2    | VOL_NUMBER       | (Optional, EARC_VOLNUMBER) Volume index in a multi-volume set.       |

`HEAD_FLAGS` for ENDARC_HEAD:

| Bit    | Mask    | Name              | Meaning                                                          |
|--------|---------|-------------------|------------------------------------------------------------------|
| 0      | 0x0001  | EARC_NEXT_VOLUME  | Another volume follows.                                          |
| 1      | 0x0002  | EARC_DATACRC      | ARC_DATA_CRC field is present.                                   |
| 2      | 0x0004  | EARC_REVSPACE     | Revision-space recovery flag.                                    |
| 3      | 0x0008  | EARC_VOLNUMBER    | VOL_NUMBER field is present.                                     |

ENDARC_HEAD is optional in RAR3: a parser that reaches end-of-file without
seeing it must not error out. Iterators should accept EOF as an equivalent
terminator after a successful FILE_HEAD walk.

### 2.7 Auxiliary block types

| HEAD_TYPE | Name           | Skip strategy                                                           |
|-----------|----------------|-------------------------------------------------------------------------|
| 0x75      | COMMENT_HEAD   | Skip HEAD_SIZE bytes; comment text is RAR2-compressed, mostly unused.   |
| 0x76      | AV_HEAD        | Skip HEAD_SIZE bytes; verification is proprietary and cannot be done.   |
| 0x77      | SUB_HEAD       | Skip HEAD_SIZE bytes plus ADD_SIZE if LONG_BLOCK flag is set.           |
| 0x78      | PROTECT_HEAD   | Skip HEAD_SIZE + ADD_SIZE; recovery payload is not needed for decode.   |
| 0x79      | SIGN_HEAD      | Skip HEAD_SIZE bytes.                                                   |
| 0x7A      | NEWSUB_HEAD    | Skip HEAD_SIZE + ADD_SIZE; carries ACLs, NTFS streams, EAs — optional.  |

A robust block iterator advances by `HEAD_SIZE + (LONG_BLOCK ? ADD_SIZE : 0)`
for every block it does not specifically consume. The HEAD_SIZE field must
itself be sanity-checked against the file length and against zero — a HEAD_SIZE
of zero would loop a naive iterator forever, and is the canonical "corruption
detected" condition.

---

## 3. RAR5 file structure

RAR5 is a clean break from RAR3 in framing. It is decisively not a superset:
the signature changed, the integer encoding changed, the header layout changed,
the hash changed (from CRC-32 to BLAKE2sp for content), the cipher changed
(AES-128 to AES-256), and the dictionary geometry changed (4 MB to up to
1 GB).

### 3.1 Signature

The eight-byte RAR5 signature is:

```
Offset  Hex                     ASCII
0x00    52 61 72 21             R a r !
0x04    1A 07 01 00             . . . .
```

The version-major byte (offset 6) is `0x01`, distinguishing RAR5 from RAR3's
`0x00`. The trailing byte is reserved.

### 3.2 Variable-length integers (vint)

RAR5 replaces RAR3's fixed-size little-endian integers with a vint encoding
borrowed from Google's Protocol Buffers / LEB128:

```
Each byte contributes 7 bits to the integer, low-order first.
The high bit (0x80) is a continuation flag: 1 = more bytes follow,
0 = this is the last byte.

Examples:
  0x00                             →  0
  0x7F                             →  127
  0x80 0x01                        →  128   (0x80 has bit-7 continuation set,
                                              0x01 contributes another 7 bits)
  0xAC 0x02                        →  300   (0x2C with continuation,
                                              then 0x02 → (2 << 7) | 0x2C)
  0xFF 0xFF 0xFF 0xFF 0x0F         →  2^32 - 1
```

The encoding is unbounded in principle; in practice values fit in 10 bytes
(uint64 maximum). A vint reader must:

1. Refuse to consume more than 10 bytes for a single value (defends against
   corruption that runs the continuation bit forever).
2. Detect truncation (continuation bit on the last byte of the input).
3. Return both the value and the number of bytes consumed, because most
   surrounding length-prefixed fields are themselves vint-sized.

### 3.3 Generic record header

Every RAR5 record (a "block" in RAR3 parlance) has the shape:

```
+----+--------+--------+--------+--------+----------+----------+--------+--------+
|CRC | hsize  | htype  | hflags | xdata  | data_sz  | header   | extra  | data   |
| 4B | vint   | vint   | vint   | vint?  | vint?    | body     | area?  | area?  |
+----+--------+--------+--------+--------+----------+----------+--------+--------+
```

| Field         | Encoding | Meaning                                                                                       |
|---------------|----------|-----------------------------------------------------------------------------------------------|
| CRC           | u32 LE   | CRC-32 of all subsequent header bytes (not including the CRC itself or any data payload).    |
| hsize         | vint     | Total header size in bytes, excluding the 4-byte CRC and the vint(hsize) itself.              |
| htype         | vint     | Record type. 1=main, 2=file, 3=service, 4=encryption, 5=end-of-archive.                       |
| hflags        | vint     | Header-wide flags: extra-area present, data-area present, dependent-on-previous, etc.         |
| xdata (size)  | vint     | If hflags & 0x0001, this is the byte length of the extra area following the header body.      |
| data_sz       | vint     | If hflags & 0x0002, this is the byte length of the data area following the extra area.        |
| header body   | bytes    | Type-specific fields (see §3.4–§3.6).                                                         |
| extra area    | bytes    | Optional extended records (extended timestamps, hashes, encryption descriptors, etc.).        |
| data area     | bytes    | Optional payload (file content for type-2/type-3 records).                                    |

#### 3.3.1 Header flags (`hflags`)

| Bit    | Mask   | Meaning                                                                                       |
|--------|--------|-----------------------------------------------------------------------------------------------|
| 0      | 0x0001 | Extra area is present and its size precedes the header body.                                  |
| 1      | 0x0002 | Data area is present and its size precedes the header body.                                   |
| 2      | 0x0004 | Block depends on the preceding block (e.g., solid-mode continuation).                          |
| 3      | 0x0008 | Block must be preserved by RAR even if it cannot be parsed (forward-compatibility for writers).|
| 4      | 0x0010 | Header contains the Data Area CRC (split blocks).                                              |
| 5      | 0x0020 | Block is a child block (e.g., split before).                                                   |
| 6      | 0x0040 | Block is a parent block (e.g., split after).                                                   |

### 3.4 Main archive record (htype = 1)

| Field         | Encoding | Meaning                                                                                       |
|---------------|----------|-----------------------------------------------------------------------------------------------|
| archive flags | vint     | Bits: 0x0001 = multi-volume, 0x0002 = volume number present, 0x0004 = solid, 0x0008 = recovery present, 0x0010 = locked, 0x0020 = original-volume-number unknown. |
| volume number | vint     | (If archive flags bit 1) Index of this volume in a multi-volume set.                          |

### 3.5 File record (htype = 2)

| Field          | Encoding | Meaning                                                                                       |
|----------------|----------|-----------------------------------------------------------------------------------------------|
| file flags     | vint     | 0x0001 = directory, 0x0002 = extended time present, 0x0004 = hash present, 0x0008 = unknown unpacked size. |
| unpacked size  | vint     | Uncompressed size (or zero if bit 3 of file flags is set).                                    |
| attributes     | vint     | Host-OS attributes (Windows or POSIX, depending on the host-OS field below if present).        |
| mtime          | u32 LE   | (Optional) Unix-epoch seconds.                                                                |
| data CRC32     | u32 LE   | (Optional) CRC-32 of the uncompressed data — for back-compat with RAR3 tooling.               |
| compression info | vint   | Packed: low 6 bits = version × 6 + algorithm, next bit = solid, next 3 bits = method (0=store, 1..5 = LZSS speeds), next 4 bits = dictionary size index. |
| host OS        | vint     | 0 = Windows, 1 = Unix.                                                                        |
| name length    | vint     | Length in bytes of the filename.                                                              |
| name           | bytes    | UTF-8 filename of `name length` bytes.                                                        |

Extra-area records inside the file record carry the BLAKE2sp content hash,
extended timestamps, AES-256 encryption descriptors, NTFS ACLs, hard-link
targets, and version annotations, each with its own type tag.

### 3.6 End record (htype = 5)

| Field         | Encoding | Meaning                                                                                       |
|---------------|----------|-----------------------------------------------------------------------------------------------|
| end flags     | vint     | 0x0001 = another volume follows.                                                              |

### 3.7 Differences from RAR3 at a glance

| Aspect                | RAR3                                       | RAR5                                                                  |
|-----------------------|--------------------------------------------|-----------------------------------------------------------------------|
| Signature length      | 7 bytes                                    | 8 bytes (high byte = 0x01)                                            |
| Integer encoding      | Fixed LE                                   | vint (LEB128)                                                         |
| Header CRC            | CRC-16                                     | CRC-32                                                                |
| File content hash     | CRC-32                                     | BLAKE2sp (256-bit) — optional CRC-32 retained for back-compat         |
| Encryption            | AES-128 with custom KDF                    | AES-256 with PBKDF2-HMAC-SHA-256                                      |
| Maximum dictionary    | 4 MB                                       | 1 GB                                                                  |
| Block types           | Fixed 0x72..0x7B                           | Open-ended vint htype; future types preserved via the "preserve" flag |
| Solid mode flag       | LHD_SOLID per entry                        | Block-dependency flag (0x0004) + main-record solid flag               |
| Filenames             | CP437 + optional compressed UTF-16 tail    | Native UTF-8                                                          |
| Recovery records      | Reed-Solomon, fixed format                 | Reed-Solomon, redesigned to interleave with data                       |

---

## 4. Compression methods

The method byte at offset 25 of the RAR3 FILE_HEAD (and the method nibble in
the RAR5 file-record compression-info vint) selects the decompression
algorithm.

| Method | Hex  | Name        | Description                                                                                  |
|--------|------|-------------|----------------------------------------------------------------------------------------------|
| Store  | 0x30 | STORE       | No compression. Raw bytes after the header. PACK_SIZE == UNP_SIZE.                           |
| 1      | 0x31 | LZSS fast   | LZSS + four-tree dynamic Huffman + 4 MB window. Encoder optimized for speed.                 |
| 2      | 0x32 | LZSS fast2  | Same bitstream as 0x31; encoder uses a slightly deeper match search.                         |
| 3      | 0x33 | LZSS normal | Default WinRAR encoder setting.                                                              |
| 4      | 0x34 | LZSS good   | Encoder uses more aggressive match-finding.                                                  |
| 5      | 0x35 | LZSS best   | Encoder uses the deepest match-finding plus filter detection.                                |
| 6      | 0x36 | PPMd        | Within an LZSS block stream, a PPMd subblock may carry text-heavy regions (RAR3 "best" mode).|

The critical observation for decoder implementers: **methods 0x31 through
0x35 all share the exact same bitstream format**. They differ only in encoder
heuristics. A single LZSS decoder handles all five. Method 0x36 is rare in
the wild and is described separately in §8.

The store method (0x30) is trivial: read PACK_SIZE bytes, verify CRC32 against
the FILE_CRC field, and emit them. There is no header inside the data payload.

---

## 5. RAR3 LZSS bitstream details

The LZSS decompressor for methods 0x31..0x35 is the core of the RAR3 format.
It is an LZSS variant with a 4 MB sliding window, four canonical Huffman
alphabets (main, length, distance, low-distance) that are themselves
encoded by a code-length pre-tree, recent-distance LRU, short-match table,
repeat-last-match support, and end-of-block + filter sentinels.

### 5.1 Bit ordering

The LZSS bitstream is read **MSB-first**: within a byte, bit 7 is consumed
before bit 0. This is opposite to deflate, which reads LSB-first within a
byte. Implementers porting deflate code must remember to reverse the bit
order.

A typical implementation maintains a 64-bit shift register and a "bits
available" counter. When the counter drops below the largest code length
the decoder might want to peek (15 bits for canonical Huffman, ≤ 25 for some
literal+extra-bit reads), the implementation pulls another byte from the
input, shifts it into the low end of the register, and increments the
counter. When the input is exhausted, subsequent reads return zero bits —
this lets the decoder finish the last codeword without explicit end-of-stream
checks on every read.

```
              bit 63                                               bit 0
              ┌─────────────────────────────────────────────────────┐
register:     │  loaded bits, MSB-first, padded with zeros at right │
              └─────────────────────────────────────────────────────┘
                    ▲
                    │ peek_bits(n): (register >> (64 - n)) & ((1 << n) - 1)
                    │ advance(n):   register <<= n; available -= n
```

### 5.2 Block structure

A method-0x31..0x35 payload consists of one or more LZSS blocks. Each block
begins with a one-bit "keep old tables" flag:

```
  bit 0:  keep_old_tables  (1 = reuse the four Huffman tables from the
                            previous block; 0 = read fresh tables now)
```

If `keep_old_tables` is 0, the decoder then reads:

```
  bit 1:  ppm_mode         (1 = this block is PPMd-coded; 0 = LZSS)
```

If `ppm_mode` is 1, the block is RAR3's method-0x36 PPMd path (see §8).
Decoders without PPMd support refuse the block here.

If `ppm_mode` is 0, the decoder reads the four Huffman tables, then enters
a symbol-decoding loop until it sees an end-of-block symbol.

### 5.3 Code-length pre-tree

The four Huffman tables — main (299 symbols), length (28 symbols), distance
(60 symbols), low-distance (17 symbols) — total 404 code-length values that
have to be transmitted at the start of every fresh table block. To compress
this metadata, RAR3 uses a **code-length pre-tree** of 20 symbols.

The pre-tree's own code lengths are sent as 20 fixed-width 4-bit values
(80 bits total). The first value is the code length for pre-tree symbol 0,
the second for symbol 1, and so on through symbol 19.

Once the pre-tree is built, the decoder reads 404 symbols from it. Most of
those symbols decode directly to a code-length value (0..15). Three symbols
are RLE expansions:

| Pre-tree symbol | Following extra bits | Meaning                                                          |
|-----------------|----------------------|------------------------------------------------------------------|
| 16              | 3 bits + 3           | Repeat the previous code length (3..10 times).                   |
| 17              | 3 bits + 3           | Insert (3..10) zero code lengths.                                |
| 18              | 7 bits + 11          | Insert (11..138) zero code lengths.                              |

Each decoded code length is **XOR'd with the corresponding code length from
the previous block** ("delta XOR"). This is the mechanism by which RAR3
exploits inter-block similarity even when full table re-use (`keep_old_tables`)
is not selected. On the very first block of an archive, the previous-block
code-length array is treated as all zeros.

### 5.4 The four Huffman alphabets

| Alphabet     | Symbols | Purpose                                                                                  |
|--------------|---------|------------------------------------------------------------------------------------------|
| Main         | 299     | 0..255 literals; 256 filter spec; 257 end-of-block; 258 repeat-last-distance; 259..262 short matches; 263..298 long matches (length code carries the implicit length, distance is decoded separately from the distance alphabet). |
| Length       | 28      | Long-match length codes for symbols 263..298 in the main alphabet — both alphabets use the same 28-entry length base/extra table.|
| Distance     | 60      | Distance codes for long matches (and short-match high bits if applicable).               |
| Low-distance | 17      | Low-bit refinement for long distances when the distance base/extra encoding exceeds 16 bits — encodes the bottom 4 bits of long distances as a separate Huffman code, with one symbol per nibble plus one for "this match uses the recent-distance LRU". |

Each alphabet is canonical Huffman with a maximum code length of 15 bits.
Codes are assigned in length-then-numerical order: shorter codes come first,
ties broken by symbol index.

### 5.5 4 MB sliding window

The decoder maintains a 4 MiB (4 × 1024 × 1024 = 4 194 304-byte) ring buffer.
After every literal emit and every match copy, the window's write pointer
advances modulo the window size. Match copies read from the window relative
to the current write pointer: a distance of 1 means "the byte just written",
a distance of 4 194 304 means "the byte written exactly one window ago".

The window's logical width (the maximum distance the decoder will see) is
controlled by `LHD_WINDOW_MASK` in the FILE_HEAD: values 0..6 select
64K, 128K, 256K, 512K, 1M, 2M, 4M respectively. WinRAR ≥ 3.0 writes the
4 MB setting (mask value 6) by default for non-tiny files.

### 5.6 Match copy semantics

A long match is decoded as:

```
1. Read a main-alphabet symbol in the range 263..298.
2. Subtract 263 to get a length index in 0..35.
   Wait — the length alphabet has 28 entries, not 36. The 263..298 range
   has 36 symbols and the length-base/extra table has 28; the mapping
   collapses the top 8 length codes via shared extra-bit slots.
3. Map the length index through the length base/extra table:
      length = length_base[index] + read_bits(length_extra[index])
4. Read a distance symbol from the distance alphabet (0..59).
5. Map it through the distance base/extra table:
      distance_base = distance_base[symbol]
      extra = distance_extra[symbol]
      if extra >= 4:
        high = read_bits(extra - 4) shifted up by 4 bits
        low  = read low-distance alphabet, 4 bits
        distance = distance_base + high + low
      else:
        distance = distance_base + read_bits(extra)
   distance += 1   // (RAR encodes (distance-1), so 0 → distance 1)
6. Copy `length` bytes from window[write - distance .. write - distance + length)
   into the output, advancing the write pointer.
7. Push `distance` onto the recent-distance LRU (size 4).
```

Short matches (main-alphabet symbols 259..262) skip the distance alphabet
entirely and use the short-match table — see §7.3.

### 5.7 End-of-block and table-refresh protocol

When the decoder reads main-alphabet symbol 257 (end-of-block), it reads
the next two bits to decide what comes next:

```
  bit 0:    1  →  end of stream
            0  →  next block
                  bit 1:  1  → next block reuses tables (no table re-send)
                          0  → next block sends fresh tables (with delta-XOR)
```

This is RAR3's mechanism for chunking the input — every few hundred KB of
output, the encoder closes the block, re-evaluates symbol frequencies, and
either commits to fresh tables (delta-XOR against the previous ones) or
keeps the existing ones for another block.

### 5.8 Filter spec symbol

Main-alphabet symbol 256 is the filter-spec sentinel. When the decoder sees
it, it does not emit a byte; instead it reads a small structured payload
(see §9) that describes a VM filter program to apply to a region of output
once it has been emitted.

---

## 6. Effect and control symbols

The 299-symbol main alphabet is the central dispatch table. Every symbol the
decoder reads from it either emits output, signals control, or initiates a
match copy.

| Range       | Count | Semantics                                                                                  |
|-------------|-------|--------------------------------------------------------------------------------------------|
| 0..255      | 256   | Literal byte. Emit this byte to the window and advance the write pointer.                  |
| 256         | 1     | Filter specification. Read a structured filter program (§9) and queue it for application.  |
| 257         | 1     | End-of-block. Read 2 more bits to decide what comes next (§5.7).                           |
| 258         | 1     | Repeat-last-distance. Use the most recent distance from the LRU; read length from §6.1.    |
| 259..262    | 4     | Short matches. Length and distance both come from the short-match table (§7.3).            |
| 263..298    | 36    | Long matches. Subtract 263, look up length in the length table (§7.1), read distance from the distance alphabet. |

### 6.1 The repeat-last-distance symbol

Symbol 258 is a one-byte optimization for runs of identical-distance matches
(e.g., a long string of zeros where every match copies from the immediately
preceding zero block). The decoder reads a length symbol from the **main
alphabet** (not the length alphabet) in the range 263..298, decodes the
length normally, and uses the distance at the head of the recent-distance LRU.

The recent-distance LRU has four slots. Symbol 258 uses slot 0. Some decoders
generalize this with three additional repeat symbols (slot 1, slot 2, slot 3),
but RAR3's spec uses only slot 0 for the repeat-last-distance shortcut — the
other slots are searched implicitly when a new long-match distance happens
to match one of them.

### 6.2 Filter program payload (symbol 256)

After symbol 256 is decoded, the decoder reads:

```
  filter_op_count:       8 bits unsigned  (number of operations in the program)
  filter_data_size:    16 bits unsigned   (size of static data the program uses)
  filter_target_size:  32 bits unsigned   (size of output region the filter
                                            will be applied to once decoded)
  filter_target_pos:   32 bits unsigned   (output-window offset where the
                                            filter applies)
  filter_program_size:  8 bits unsigned   (size in bytes of the bytecode)
  filter_program:      filter_program_size bytes of VM bytecode
  filter_data:         filter_data_size bytes of inline static data
```

The exact field encoding is more compact than this pseudo-layout shows —
the real encoding uses variable-width reads (3-bit micro-opcodes for common
filter selectors, plus the inline-data block) — but the spirit is the same.
See §9 for the VM details.

---

## 7. Static lookup tables

The four Huffman alphabets share three large lookup tables whose contents
are part of the RAR3 spec (not transmitted with each archive). These tables
specify how main-alphabet symbols 263..298, distance-alphabet symbols 0..59,
and the short-match index 0..7 map to (base, extra-bit-count) pairs.

### 7.1 Length table

The length table has 28 entries. Each entry gives a base length and a count
of additional bits the decoder must read from the bitstream and add to the
base.

| Index | Base | Extra bits | Resulting range |
|-------|------|------------|-----------------|
| 0     | 3    | 0          | 3               |
| 1     | 4    | 0          | 4               |
| 2     | 5    | 0          | 5               |
| 3     | 6    | 0          | 6               |
| 4     | 7    | 0          | 7               |
| 5     | 8    | 0          | 8               |
| 6     | 9    | 0          | 9               |
| 7     | 10   | 0          | 10              |
| 8     | 11   | 1          | 11..12          |
| 9     | 13   | 1          | 13..14          |
| 10    | 15   | 1          | 15..16          |
| 11    | 17   | 1          | 17..18          |
| 12    | 19   | 2          | 19..22          |
| 13    | 23   | 2          | 23..26          |
| 14    | 27   | 2          | 27..30          |
| 15    | 31   | 2          | 31..34          |
| 16    | 35   | 3          | 35..42          |
| 17    | 43   | 3          | 43..50          |
| 18    | 51   | 3          | 51..58          |
| 19    | 59   | 3          | 59..66          |
| 20    | 67   | 4          | 67..82          |
| 21    | 83   | 4          | 83..98          |
| 22    | 99   | 4          | 99..114         |
| 23    | 115  | 4          | 115..130        |
| 24    | 131  | 5          | 131..162        |
| 25    | 163  | 5          | 163..194        |
| 26    | 195  | 5          | 195..226        |
| 27    | 227  | 5          | 227..258        |

### 7.2 Distance table

The distance table has 60 entries. Same structure: base distance + extra bits.

| Index | Base       | Extra bits |
|-------|------------|------------|
| 0     | 0          | 0          |
| 1     | 1          | 0          |
| 2     | 2          | 0          |
| 3     | 3          | 0          |
| 4     | 4          | 1          |
| 5     | 6          | 1          |
| 6     | 8          | 2          |
| 7     | 12         | 2          |
| 8     | 16         | 3          |
| 9     | 24         | 3          |
| 10    | 32         | 4          |
| 11    | 48         | 4          |
| 12    | 64         | 5          |
| 13    | 96         | 5          |
| 14    | 128        | 6          |
| 15    | 192        | 6          |
| 16    | 256        | 7          |
| 17    | 384        | 7          |
| 18    | 512        | 8          |
| 19    | 768        | 8          |
| 20    | 1024       | 9          |
| 21    | 1536       | 9          |
| 22    | 2048       | 10         |
| 23    | 3072       | 10         |
| 24    | 4096       | 11         |
| 25    | 6144       | 11         |
| 26    | 8192       | 12         |
| 27    | 12288      | 12         |
| 28    | 16384      | 13         |
| 29    | 24576      | 13         |
| 30    | 32768      | 14         |
| 31    | 49152      | 14         |
| 32    | 65536      | 15         |
| 33    | 98304      | 15         |
| 34    | 131072     | 16         |
| 35    | 196608     | 16         |
| 36    | 262144     | 18         |
| 37    | 327680     | 18         |
| 38    | 393216     | 18         |
| 39    | 458752     | 18         |
| 40    | 524288     | 18         |
| 41    | 589824     | 18         |
| 42    | 655360     | 18         |
| 43    | 720896     | 18         |
| 44    | 786432     | 18         |
| 45    | 851968     | 18         |
| 46    | 917504     | 18         |
| 47    | 983040     | 18         |
| 48    | 1048576    | 18         |
| 49    | 1114112    | 18         |
| 50    | 1179648    | 18         |
| 51    | 1245184    | 18         |
| 52    | 1310720    | 18         |
| 53    | 1376256    | 18         |
| 54    | 1441792    | 18         |
| 55    | 1507328    | 18         |
| 56    | 1572864    | 18         |
| 57    | 1638400    | 18         |
| 58    | 1703936    | 18         |
| 59    | 1769472    | 18         |

The repetitive top of the table (indices 36..59 all carrying 18 extra bits)
reflects the fact that distances above 256 KB are uncommon enough that
WinRAR can afford to allocate them a coarse Huffman index and recover
precision from the 18 extra bits. For distances where extra bits ≥ 4, the
extra-bit value is decoded in two pieces: the high bits as raw bitstream
reads, and the low 4 bits as a code from the low-distance alphabet (§7.4).
That split makes the low bits cheaper to encode when they cluster around a
small set of values (common for binary-aligned data).

The distance-table construction in source can be derived from a compact
nine-element seed array `distanceBitLengthCounts = [4, 4, 4, 4, 4, 4, 4, 4,
4, 4, 4, 4, 12, 14, 16, 24]` (a per-segment count of how many indices share
the same extra-bit width); SwiftRAR computes the table from that seed at
load time.

### 7.3 Short-match table

The short-match table has 8 entries. Short matches (main-alphabet symbols
259..262, plus the implicit short-match alphabet) skip the regular length
and distance alphabets entirely.

| Index | Base distance | Extra bits |
|-------|---------------|------------|
| 0     | 0             | 0          |
| 1     | 4             | 0          |
| 2     | 8             | 0          |
| 3     | 16            | 1          |
| 4     | 32            | 2          |
| 5     | 64            | 3          |
| 6     | 128           | 4          |
| 7     | 192           | 5          |

A short match's length is one of {2, 3, 4, 5} and is determined by which of
the four short-match symbols (259..262) was read from the main alphabet.
The short-match table is consulted only for the **distance** portion. The
short-match path exists because two- and three-byte matches at small
distances are extremely common in compressed text and binary, and a
dedicated coding path saves several bits per occurrence over routing them
through the long-match machinery.

### 7.4 Low-distance alphabet

The low-distance alphabet has 17 symbols. Symbols 0..15 each represent a
specific value for the low 4 bits of a distance (i.e., symbol 5 means "the
low 4 bits of this distance are 0b0101"). Symbol 16 is the
"use-recent-distance-LRU" sentinel: when read in the context of a long
match whose distance has extra bits ≥ 4, it means "don't take the high
bits from the bitstream; instead reuse a distance from the recent-distance
LRU". The exact LRU slot is determined by the high bits that would otherwise
have been read (the encoding uses 0, 1, or 2 additional bits to select the
LRU slot when symbol 16 is taken).

The low-distance alphabet is the smallest of the four Huffman codes (only
17 symbols, max 15 bits per code) but it appears in the bitstream on every
long-distance match, so its compactness matters for overall ratio.

---

## 8. PPMd subblock (method 0x36)

RAR3's "best" compression mode (method byte 0x36) can mix LZSS blocks with
PPMd-coded blocks. The PPMd block is selected by the `ppm_mode` bit in the
block header (§5.2). When it is set, the rest of the block is not LZSS at
all — it is a PPMd-coded byte stream that emits directly into the output
(no Huffman, no sliding window, no filters — PPMd is its own world).

### 8.1 What PPMd is

PPMd (Prediction by Partial Matching, variant d) is a context-mixing
compression algorithm by Dmitry Shkarin, based on Cleary and Witten's
original PPM and Moffat's PPMC. It maintains a Markov model of variable
order: for each output byte, it conditions its probability estimate on a
context of up to N preceding bytes (the "order"), falling back to a
shorter context when the longer one has not been seen before. PPMII
("Information Inheritance") is Shkarin's specific variant that propagates
escape-probability and statistics from longer contexts down to shorter
ones, giving better ratios at the cost of significantly more memory and
arithmetic per byte.

The encoded byte stream is an **arithmetic-coded** sequence of probability
updates and symbol emissions. There is no Huffman decoder here at all;
arithmetic coding maintains an interval [low, high) over a 32-bit range
and refines it bit-by-bit toward a single point that corresponds to the
encoded message.

RAR3's PPMd block carries:

1. A model-reset signal at the start (whether to inherit state from the
   previous PPMd block or start fresh).
2. The arithmetic-coded byte stream itself.
3. An escape sequence (the byte 0x02 from the model output) signals
   end-of-stream and switches the decoder back into LZSS-block mode for
   subsequent blocks within the same method-0x36 file.

### 8.2 Patent encumbrance

PPMII / PPMd-J1 as implemented by Shkarin has historically been encumbered
by patent and proprietary-license claims. Every shipping implementation —
7-Zip, unrar, libarchive — inherits from Shkarin's own source code under
terms that do **not** permit clean-room MIT/Apache redistribution. There
is no specification document independent of that source: the algorithm
is the source.

For an MIT/Apache-licensed Swift library, this means the PPMd path is
permanently out of scope. SwiftRAR detects the `ppm_mode` bit in the
block header, refuses with `RARError.unsupportedFeature(...)`, and is
explicit in its README that PPMd archives must be routed to a tool that
inherits from the unrar lineage (The Unarchiver on macOS, 7-Zip elsewhere).

Implementers building under permissive licenses should not attempt PPMd —
the legal exposure is real and the algorithmic description in compression
textbooks is insufficient to clean-room a compatible implementation. The
RAR3 PPMd block format itself is documented in technote.txt; the **arithmetic
coder and model** that interpret it are not.

---

## 9. Multimedia filters and the RAR VM

The filter spec (main-alphabet symbol 256) is RAR3's mechanism for applying
content-aware post-processing to decoded output. Filters do not change the
compressed bitstream; they run after a region of output has been emitted,
correcting it in place to undo a transform the encoder applied to make
the data more LZSS-compressible.

### 9.1 The five built-in filters

The five filters that ship with WinRAR's encoder are:

| Filter            | Operates on                          | Transformation                                                                                          |
|-------------------|--------------------------------------|---------------------------------------------------------------------------------------------------------|
| E8                | x86 executables                      | Replace absolute call/jmp targets (0xE8/0xE9 opcode) with relative offsets so identical calls collapse. |
| E8/E9             | x86 executables (E8 + E9 variant)    | Same as E8 but extends to E9 (unconditional jmp) instructions.                                          |
| Itanium           | IA-64 executables                    | Apply equivalent call-target normalization for Itanium branch bundles.                                  |
| RGB delta         | 24-bit BMP or similar RGB streams    | Delta-encode each color channel against the same channel in the previous pixel.                         |
| Audio delta       | 16-bit PCM audio                     | Delta-encode each sample against the previous sample on the same channel.                               |
| ARM branch        | 32-bit ARM executables               | Normalize the offset of B/BL branch instructions to a canonical form.                                   |

The encoder runs a small classifier over its input window and inserts a
filter-spec symbol when it sees a region whose statistics match one of
these predefined filters. The decoded LZSS output for that region is the
**transformed** form (e.g., all x86 call targets normalized to zero-relative);
the filter, when applied at output time, reverses the transformation and
restores the original bytes.

### 9.2 The RAR VM

In addition to the five built-in filters, RAR3 ships a small bytecode VM
that can execute arbitrary filter programs delivered inline in the
compressed stream. The VM has:

- 8 general-purpose registers (`r0..r7`), 32-bit each.
- A flags register (zero, sign, carry — like an x86 EFLAGS).
- A small memory area (the size matches the filter's `target_size`).
- An instruction set of roughly 40 opcodes: mov, add, sub, jz/jnz/js/jc,
  cmp, test, shl/shr, and/or/xor, push/pop, call/ret, and a few
  specialized ones (sar — arithmetic shift right, neg, not, inc, dec,
  mul, div).
- Addressing modes: register, memory at register, memory at immediate,
  immediate constant.

The VM is little-endian, byte-addressable for memory operations, and has
no I/O — it operates strictly on the filter's input buffer (the output
region the filter is being applied to) plus the filter's static data
block. Programs return by emitting a `ret` instruction that pops a target
address off the stack (initialized at program start to point at the end of
the buffer); when the program counter reaches that address, the filter is
done.

In practice the inline VM is rare. The built-in filters cover the vast
majority of multimedia and executable data, and WinRAR's encoder uses
custom VM programs only when an explicit profile is loaded. Reachable
implementations like `rarfile.py` and the Kaitai Struct RAR spec document
the bytecode and most decoders implement at least the five built-in
filters with hand-written code, deferring full VM execution to whenever an
archive actually requires it.

### 9.3 Filter execution order

Within a single LZSS block, multiple filter specs can be in flight at once
(symbol 256 is read but the filter does not execute until enough output has
been produced to cover its target region). The decoder maintains a queue:

1. When symbol 256 is decoded, parse the spec and push a record onto the
   queue: (target_pos, target_size, program_id, static_data).
2. Continue decoding literals and matches into the output window.
3. After each byte (or each match copy) is emitted, check whether the
   head of the queue's `target_pos + target_size` has now been reached.
4. If so, dequeue the record and run the filter over the corresponding
   output bytes in place. The filter's output replaces those bytes in
   the window — subsequent matches that reference distances into the
   filtered region see the filter's output, not the pre-filter bytes.

### 9.4 SwiftRAR status

SwiftRAR currently consumes the filter spec bytes from the bitstream (so
the decoder stays in sync with the rest of the LZSS state machine) but
**does not execute** the filter program. For unfiltered archives (the
overwhelming majority of textmode-era RAR files in the audit's target
corpus), the output is correct. For archives whose encoder inserted
filters (typically x86 binaries, BMPs, PCM audio), the output will differ
from the original input — generally the bytes immediately after a filter
spec will look like normalized call targets rather than absolute addresses.

VM filter execution is a tracked deferred feature; the spec is public
(technote.txt + rarfile.py + Kaitai Struct RAR cover the bytecode and the
five built-in filters), and the effort estimate is roughly one focused
week.

---

## 10. Solid mode

Solid mode is RAR's term for compressing multiple file entries against a
**shared sliding window**, so that match references inside file N can
reach back into the decoded output of files 0..N-1. The compression ratio
gain is substantial when an archive contains many small similar files
(e.g., a directory of source code or a set of similarly-laid-out
configuration files).

### 10.1 How it works on disk

When MHD_SOLID (0x0008) is set in the main archive header, every FILE_HEAD
that has LHD_SOLID (0x0010) set is encoded against the dictionary state
left over from the **end of the previous solid entry's decoded output**.
The decoder must:

1. Initialize the 4 MB sliding window once, at the start of the archive.
2. For each FILE_HEAD with LHD_SOLID set, decode its data into the same
   window — do not reset the window, do not reset the recent-distance LRU,
   do not reset the Huffman tables (the keep_old_tables flag at the start
   of the first block of the new entry decides whether to reuse the tables
   from the end of the previous entry).
3. For each FILE_HEAD without LHD_SOLID set in a MHD_SOLID archive, reset
   the dictionary at that entry's boundary. (Some archives mix solid and
   non-solid entries; this is rare but legal.)
4. CRC32 verification still happens per-entry over each entry's
   uncompressed output.

### 10.2 Why random access is impossible

In a non-solid archive, a decoder can seek to the FILE_HEAD of any entry
and extract it without touching the others — each entry's compressed
stream is self-contained. In a solid archive, every entry's compressed
stream **depends on the decoded output of all previous solid entries**.
Extracting the third file out of a hundred requires decompressing the
first two as well. This is the price of the ratio improvement, and it
is why archive software typically warns the user when they request to
extract a single file from a solid archive (the operation is correct but
slow).

### 10.3 SwiftRAR status

SwiftRAR currently rejects MHD_SOLID archives at iteration time with
`RARError.unsupportedFeature("solid mode")`. The implementation is a
tracked deferred feature with an effort estimate of 2-3 days: the
current decoder instantiates a fresh window per entry, and the fix is to
hold a per-archive decoder instance across iterator advances and only
reset its state when an entry without LHD_SOLID appears. The bounds of
the change are well-contained; the spec is fully public.

---

## 11. CRC32 and recovery records

### 11.1 CRC32 for entry payloads

RAR3 uses the IEEE 802.3 CRC-32, identical to the one used by Ethernet,
ZIP, gzip, and PNG. The reflected polynomial is `0xEDB88320`. Each
FILE_HEAD carries a 32-bit `FILE_CRC` field giving the CRC of the
**uncompressed** data. After decompressing an entry, the decoder must
compute the CRC over its output and compare; a mismatch indicates either
data corruption or a decoder bug.

A reference table-driven implementation:

```
crc_table[256]:
  for i in 0..255:
    c = i
    for j in 0..7:
      if c & 1:
        c = (c >> 1) ^ 0xEDB88320
      else:
        c = c >> 1
    crc_table[i] = c

crc32(data):
  crc = 0xFFFFFFFF
  for byte in data:
    crc = (crc >> 8) ^ crc_table[(crc ^ byte) & 0xFF]
  return crc ^ 0xFFFFFFFF
```

The table can be computed lazily and cached; SwiftRAR builds it once and
exposes a `Data`-fast-path `CRC32.compute(data)` API.

### 11.2 Header CRC16

Each RAR3 block carries a `HEAD_CRC` field in its first two bytes. This is
a CRC-16/IBM (polynomial `0xA001` reflected). Strict decoders validate
HEAD_CRC against the bytes from HEAD_TYPE through the end of the header;
lenient decoders skip the check. SwiftRAR currently reads HEAD_CRC but
does not validate it; the validation is a tracked deferred item (half a
day of work).

### 11.3 Recovery records

RAR's recovery records are a Reed-Solomon encoding overlaid on the archive
at 512-byte sector granularity. The PROTECT_HEAD (0x78) block in RAR3 and
the equivalent service record in RAR5 carries the Reed-Solomon parity bytes
plus an index telling the decoder which sectors of the archive they
correspond to. If a few sectors of the archive are damaged (bad media,
truncated download), the recovery payload can reconstruct them.

The Reed-Solomon code itself is over GF(256) with a fixed primitive
polynomial; the specific parameters are documented in technote.txt. SwiftRAR
parses PROTECT_HEAD as an opaque block (skipped during iteration) but does
not perform repair — recovery is a tracked deferred item for a much later
phase.

---

## 12. The encoder side, briefly

This is the part of the format that is **closed**. WinRAR — the canonical
encoder — is proprietary commercial software. The publicly available
`unrar` source code is a decoder only; its license forbids using its code
or implementation details to build a compatible compressor.

No publicly available specification describes the encoder. `technote.txt`
shipped with WinRAR up through version 4.x describes only the on-disk
bitstream that a **decoder** must consume. It does not describe:

- The match-finding algorithm (hash chain depth, lazy-match thresholds,
  match-length policies, the encoder's choice between short-match and
  long-match paths for ambiguous lengths).
- The Huffman tree construction (the encoder's frequency-counting strategy,
  block-flush heuristics, table-reuse decisions).
- The filter detection (how the encoder classifies a region as x86 vs ARM
  vs RGB delta vs uncompressible, the size and shape of its sliding
  classifier window, the false-positive guards).
- The PPMd model selection (when to switch from LZSS to PPMd, the order
  parameter, the memory budget, the model reset policy).
- The VM filter generation (when, if ever, WinRAR emits a custom VM
  program instead of a built-in filter).

No open-source RAR compressor has ever shipped. Not in `unrar` (decode-only
by license). Not in libarchive (decode-only). Not in 7-Zip (decode-only,
explicitly). Attempting one would be a clean-room re-derivation of a
closed format, which is legally hazardous, and would in practice produce
something that decompresses correctly only if every consumer is also
implemented from the same re-derivation.

SwiftRAR is a decoder library. It does not attempt compression and does
not stub out a writer surface. This is the right scope.

---

## 13. References

### 13.1 Primary specification sources

| Source                          | License                         | Coverage                                                                  |
|---------------------------------|---------------------------------|---------------------------------------------------------------------------|
| WinRAR `technote.txt` (≤ 4.x)   | Copyright win.rar GmbH; routinely cited under interop fair-use | RAR3 block formats, FILE_HEAD/MAIN_HEAD fields, method bytes, the LZSS bitstream at a high level, filter-spec encoding. The canonical reference. |
| WinRAR `UnRARSrc` `unpack.cpp`  | Custom unrar source license — read-only, not redistributable in derivative compressors | The reference C++ decoder implementation. Cite for spec confirmation; do not copy code. |
| Kaitai Struct RAR specification | Permissive (MIT-style)         | A clean re-derivation of the RAR3 block structure as a Kaitai .ksy file. Suitable as a base for clean-room implementations. |
| `rarfile.py` (Marko Kreen)      | ISC (permissive)               | Pure-Python decoder covering RAR3 LZSS, RAR3 STORE, filename encoding, recovery-record parsing, and RAR5 base-header walks. Excellent reference and citable. |
| 7-Zip RAR sources               | LGPL — citable but not copyable| Detailed C++ decoder for both RAR3 and RAR5. Cite for behavioral confirmation; **do not** copy code into a permissive project. |
| Wikipedia "RAR (file format)"   | CC BY-SA                       | High-level history, version timeline, format-comparison context.          |

### 13.2 Format-adjacent technical references

| Source                                       | Coverage                                                                  |
|----------------------------------------------|---------------------------------------------------------------------------|
| Salomon & Motta, *Handbook of Data Compression*, 5th ed. | LZSS, canonical Huffman, arithmetic coding, PPM family theory. |
| Cleary & Witten, "Data Compression Using Adaptive Coding and Partial String Matching" (IEEE Trans. Comm. 1984) | Original PPM paper. |
| Shkarin, "PPM: One Step to Practicality" (DCC 2002) | PPMII algorithm description (the variant RAR3 uses for method 0x36). |
| RFC 1951 (DEFLATE)                           | Reference for canonical Huffman, MSB vs LSB bitstream ordering, and how DEFLATE differs from RAR3's bitstream conventions. |
| ISO/IEC 13818-2 §6.2.3                       | Reed-Solomon over GF(256) — the math that underlies RAR recovery records. |
| RFC 7693 (BLAKE2)                            | BLAKE2sp specification — RAR5's content hash.                              |

### 13.3 URLs

- WinRAR / technote.txt: shipped with the WinRAR distribution; `unrar` source
  is mirrored at `rarlab.com/rar_add.htm` and `github.com/aawc/unrar` and
  similar mirrors.
- Kaitai Struct RAR spec: `github.com/kaitai-io/kaitai_struct_formats` —
  see `archive/rar.ksy`.
- rarfile.py: `github.com/markokr/rarfile`. ISC-licensed.
- 7-Zip sources: `7-zip.org/sdk.html` and `github.com/mcmilk/7-Zip-zstd`.
- Wikipedia: `en.wikipedia.org/wiki/RAR_(file_format)`.

---

## 14. SwiftRAR scope

SwiftRAR is a Swift decoder library for the RAR3 archive format. It is
not a codec (no compression), not a 100%-WinRAR-compatible reader (PPMd
is permanently out of scope), and not a hex viewer (the API surface
returns extracted bytes or typed errors). This section enumerates
exactly what is built, what is on the roadmap, and what is and will
remain out of scope, with the rationale for each item.

### 14.1 Implemented

- `RARError` — typed error vocabulary: `notRAR`, `truncated`, header CRC
  mismatch, data CRC mismatch, `unsupportedCompression(method:)`,
  `unsupportedFeature(String)`, `entryOffsetOutOfRange`.
- RAR3 signature detection with a 1 MiB SFX-stub scan window. Both the
  bare `Rar!\x1a\x07\x00` magic and SFX-prefixed archives parse.
- RAR5 signature detection. RAR5 archives are recognized as RAR
  (not misclassified as notRAR) and then refused with
  `unsupportedFeature("RAR5 block parsing")` so the caller can route to
  another tool.
- RAR3 MAIN_HEAD (0x73) parser with main-flags decoding for
  volume / solid / password / lock / new-numbering.
- RAR3 FILE_HEAD (0x74) parser, including:
  - Large-file (> 4 GB) high-word handling for PACK_SIZE and UNP_SIZE.
  - CP437/Latin-1 filename pass-through. The compressed UTF-16 tail is
    skipped, not decoded — see deferred items.
  - DOS timestamp decoding.
  - Host-OS attribute pass-through.
  - Method byte, CRC32, ATTR, HOST_OS — all exposed as `RAREntry` fields.
- RAR3 block-stream iterator that walks every block type, dispatches
  MAIN/FILE/ENDARC, skips auxiliary types (COMMENT/AV/SUB/PROTECT/SIGN/NEWSUB),
  and guards against zero-advance corruption loops.
- Bounds-checked little-endian `ByteReader` for header parsing.
- Public value-type `RAREntry` (name, sizes, method, CRC32, host-OS,
  attributes, modDate, flags, dataOffset).
- Public static API `RARArchive.entries(_:)`, `RARArchive.extract(entry:from:)`,
  `RARArchive.isRARArchive(_:)`.
- STORE method (0x30) extraction with CRC32 verification and entry-offset
  guards.
- CRC32 — IEEE 802.3, reflected polynomial 0xEDB88320, lazily-built lookup
  table with a `Data` fast path.
- MSB-first `BitStream` with a 64-bit shift register, `peek` / `advance` /
  `readBits` / `alignToByte`, and graceful tail-zero behavior at exhaustion.
- Canonical Huffman decoder (`RAR3HuffmanDecoder`) — max 15 bits,
  over-subscription detection, empty-table sentinel.
- RAR3 code-length pre-tree decoder with delta-XOR against the previous
  block, and 16/17/18 RLE expansion symbols.
- RAR3 LZSS lookup tables — length base/extra (28 entries), distance
  base/extra (60 entries, computed from the 16-element seed array
  `distanceBitLengthCounts`), short-match distance table (8 entries),
  low-distance alphabet constants.
- RAR3 LZSS block driver for methods 0x31..0x35:
  - 4 MB sliding window.
  - Four-tree Huffman dispatch (main / length / distance / low-distance).
  - Recent-distance LRU.
  - Short-match path (main symbols 259..262).
  - Long-match path with the high/low split for distances with extra
    bits ≥ 4.
  - Repeat-last-distance (symbol 258).
  - Keep-old-tables flag honoring.
  - End-of-block protocol (1 / 00 / 01).
- Method-byte dispatch in `RARArchive.extract` — routes 0x30 to
  `StoreExtractor`, 0x31..0x35 to `RAR3LZSSDecoder`, rejects encrypted /
  solid / unknown methods with typed errors.
- 47 passing tests covering signature detection, header parsing, store
  extraction, LZSS extraction, CRC verification, and error-typing edges.

### 14.2 Deferred (reachable from public spec)

These items are absent today but their specifications are public and
their effort is bounded. They form the roadmap for a "100% of the
publicly-documented decoder surface" target.

| Feature                                       | Effort      | Rationale |
|-----------------------------------------------|-------------|-----------|
| VM filter execution (E8/E8E9, RGB delta, audio delta, ARM, custom-program VM) | ~1 week | Spec is public (technote + rarfile.py + Kaitai). Filter spec parsing is already wired into the LZSS decoder; only the execution engine is missing. Without it, filtered binaries decompress to the pre-filter (uncorrected) bytes — correct for unfiltered archives, wrong for filtered ones. |
| Solid-mode dictionary inheritance              | 2-3 days    | Spec is straightforward — the sliding window must persist across FILE_HEAD boundaries when MHD_SOLID is set. The fix is to hold a per-archive decoder instance across iterator advances. |
| UTF-16-compressed filename decoding (LHD_UNICODE secondary stream) | 1-2 days | The compression scheme is documented in technote and rarfile.py implements it cleanly. Non-blocking for ASCII filenames. |
| Header CRC16 verification                      | half a day  | Pure correctness hardening. CRC16/IBM is trivial; the field is already read into a local. |
| RAR5 base-header vint parsing + block walk     | 1-2 weeks   | Spec is public (unrar5 technote shipped 2013-2014 alongside WinRAR 5.0; rarfile.py covers the same surface in ISC). This is a separate parser cluster from RAR3, not a refactor of it. |
| RAR5 LZSS-family decompressor                  | 2-3 weeks   | RAR5 changed the dictionary geometry (up to 1 GB), the symbol alphabet sizes, and the filter set, but the bitstream shape and canonical-Huffman machinery are familiar. The BitStream + Huffman decoder + table-refresh scaffolding already in the package transfers directly. |
| Multi-volume continuation (`.r00` / `.partNN.rar`) | 3-5 days | Iterator currently rejects volume archives. Joining volumes is a stream-concatenation problem at the byte level plus split-before/split-after FILE_HEAD flag handling — both well documented. |
| Recovery records (PROTECT_HEAD 0x78 / RAR5 recovery service) parsing and repair | 1-2 weeks | RAR's recovery format is documented (Reed-Solomon over 512-byte sectors). Reachable in principle but out of scope for a decoder-only library shipping its first release. |
| AES-128 / AES-256 entry decryption (password-derived key) | ~1 week | Both RAR3 (AES-128 + custom KDF) and RAR5 (AES-256 + PBKDF2-SHA-256) are publicly documented. CommonCrypto / CryptoKit provide the primitives. Currently throws `unsupportedFeature("encrypted entries")`. Substantial security-sensitive cluster — should ship with a careful threat model. |
| RAR5 BLAKE2sp content-hash verification        | 1-2 days (if a BLAKE2sp dep is acceptable) | Not unreachable — BLAKE2sp is RFC 7693 + parallel-mode. Flagged because Swift's first-party ecosystem doesn't ship BLAKE2sp and adopting a dependency is a meaningful decision. |

### 14.3 Permanently out of scope

These items are not on the roadmap, will not be added, and the rationale
for excluding them is documented here so the next phase of work does not
relitigate them.

**PPMd decompression (Shkarin PPMII — RAR3 method 0x36).** PPMII / PPMd-J1
by Dmitry Shkarin is covered by patent and proprietary-license claims that
remain in effect as of 2025. Every shipping implementation (7-Zip, unrar)
inherits from Shkarin's own source under terms that do not permit clean-room
MIT/Apache redistribution. There is no specification document independent
of that source — the algorithm is the source. SwiftRAR rejects PPMd-mode
blocks at the bitstream level with `RARError.unsupportedFeature("RAR3 PPMd
block ... requires PPMII port")` and is explicit about this in the README.

**RAR compression / archive writing.** The RAR format is closed-source on
the writer side. WinRAR is proprietary commercial software. The public
`technote.txt` describes only the bitstream a decoder must consume, not
the match-finder, entropy-coder, or filter-detection choices the encoder
makes. No open-source RAR compressor has ever shipped — not in unrar
(decode-only by license), not in libarchive, not in 7-Zip. Attempting one
would be a clean-room re-derivation of a closed format (legally hazardous)
or fabrication.

**WinRAR AV-block (0x76) cryptographic verification.** AV records use a
WinRAR-proprietary signing scheme whose verification keys and algorithm
details have never been published. Parsing the block structure is reachable
(SwiftRAR skips the block as an unknown auxiliary type); verifying it
cryptographically is not.

### 14.4 Honest README positioning

SwiftRAR's README presents the library as a decoder for STORE (0x30) and
RAR3 LZSS (0x31..0x35) archives. It rejects encrypted, solid, multi-volume,
PPMd-mode, and RAR5 inputs with typed `RARError` values so callers can
route users to a more capable tool (The Unarchiver on macOS, 7-Zip
elsewhere). This is what is actually built, and it is sufficient for the
target use cases (textmode-era archives, plain stored or LZSS-compressed
content, single-volume non-encrypted non-solid). It is not sufficient as
a drop-in WinRAR replacement, and the README does not claim otherwise.

The deferred items (§14.2) are a published roadmap. The unreachable items
(§14.3) are published non-goals. Together they describe an honest scope
that matches what the package can credibly ship and maintain.
