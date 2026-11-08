# RAR Archive Format Reference

A byte-level reference for reading RAR archives: the RAR 1.5–4.x container,
the RAR 5.0 container, the RAR 2.9 compressed bitstream used by RAR/WinRAR
3.x and 4.x, and the checksums that protect them. It is written for
implementers of extractors and archive inspectors.

This document is the authoritative specification for SwiftRAR. Section 10
maps every feature described here to SwiftRAR's support level, and §11
records how the document was written (its provenance).

| | |
|---|---|
| Revision | 2026-11-08 |
| Covers | RAR 1.5–4.x container (complete), RAR 5.0–7.x container (complete), RAR 2.9 LZ bitstream (complete), CRC-32 and header CRC |
| Summarised only | RAR 1.5 / 2.0 / 5.0 bitstreams, PPMd blocks, filter programs, encryption, recovery records |
| Language | All prose, tables and pseudocode are original to this document |

---

## 1. Overview

### 1.1 What RAR is

RAR ("Roshal ARchive") is a proprietary archive and compression format
created by Eugene Roshal. Archives are written by RARLAB's own tools: the
command-line `rar` (DOS, then Windows, Linux, macOS and FreeBSD builds),
WinRAR for Windows, and RAR for Android. RARLAB publishes the container
layout (a `technote.txt` file shipped with RAR up to 4.x, and an HTML
description of the RAR 5.0 format on rarlab.com) but not the compression
algorithms. "RAR" and "WinRAR" are trademarks of their owner; the format is
maintained by RARLAB (win.rar GmbH).

Many third-party programs read RAR archives (RARLAB's own source-available
`unrar`, 7-Zip, libarchive/bsdtar, The Unarchiver and others). Only RARLAB's
tools create them.

### 1.2 Generations

The container and the compression algorithm are versioned separately. The
container has two generations, told apart by the signature; the compression
algorithm of each entry is identified by a version number in its header.

| Container | Signature (hex) | Written by | Compression algorithms that appear inside |
|-----------|-----------------|------------|-------------------------------------------|
| RAR 1.3/1.4 | `52 45 7E 5E` (`RE~^`) | RAR ≤ 1.4x (1993–1994) | RAR 1.3 (undocumented; not covered here) |
| RAR 1.5–4.x ("classic") | `52 61 72 21 1A 07 00` | RAR 1.50 to WinRAR 4.x, and WinRAR 5+ when asked for the RAR4 format | 1.5, 2.0, 2.9 (§5.3) |
| RAR 5.0+ | `52 61 72 21 1A 07 01 00` | WinRAR/RAR 5.0 (2013) and later | RAR 5.0 (algorithm version 0), RAR 7.0 (algorithm version 1) |

Algorithm generations inside the classic container:

| Algorithm | Introduced with | Main traits |
|-----------|-----------------|-------------|
| RAR 1.5 | RAR 1.50 | Adaptive coding with a 64 KiB window. |
| RAR 2.0 | RAR/WinRAR 2.0 | LZ77 with per-block Huffman tables, window up to 1 MiB, an optional "multimedia" (audio prediction) mode. |
| RAR 2.9 | WinRAR 3.00 (2002) | LZ77 with four per-block Huffman tables and a window up to 4 MiB; blocks may instead be PPMd-coded; optional preprocessing filters expressed as programs for a small virtual machine. Also used by WinRAR 4.x. |

RAR 3.x also introduced AES-128 encryption, Unicode file names, extended
timestamps, service sub-headers and the `name.partNN.rar` volume naming.
RAR 5.0 replaced the container (variable-length integers, CRC-32 header
checks, BLAKE2sp file hashes, AES-256, larger dictionaries) and the
compression algorithm; it dropped PPMd and the virtual-machine filters in
favour of a fixed set of built-in filters.

### 1.3 File extensions, MIME type, UTI

| Item | Value |
|------|-------|
| Extension | `.rar`; old-style volumes `.rar`, `.r00`, `.r01`, …; new-style volumes `.part1.rar`, `.part2.rar`, …; self-extracting archives usually `.exe`; comic-book archives `.cbr` |
| MIME type | `application/vnd.rar` (IANA registration); `application/x-rar-compressed` is the older unregistered name still in wide use |
| Uniform Type Identifier | None is declared by Apple's system type catalogue; `com.rarlab.rar-archive` is the identifier commonly exported by third-party applications |

### 1.4 Telling variants apart

1. Search for a signature (§3.1). `RE~^` at offset 0 means RAR 1.3/1.4.
   `Rar!\x1A\x07\x00` means the classic container, `Rar!\x1A\x07\x01\x00`
   the RAR 5.0 container. Any other byte after `Rar!\x1A\x07` is not a known
   RAR signature.
2. In the classic container, each FILE_HEAD's `UNP_VER` (§3.6) names the
   compression algorithm of that entry (§5.3). One archive may mix
   generations.
3. In the RAR 5.0 container, the compression-information field of each file
   header (§4.6.1) names the algorithm version.

---

## 2. Conventions

- **Byte order.** Every multi-byte integer is little-endian unless stated.
- **Integer types.** `u8`, `u16`, `u32`, `u64` are unsigned integers of 8,
  16, 32 and 64 bits. `vint` is the RAR 5.0 variable-length integer (§4.2).
  No field is signed.
- **Offsets** in layout tables are relative to the start of the structure
  being described. "HEAD_SIZE bytes from the block start" includes the CRC
  field.
- **Bit numbering.** Bit 0 is the least significant bit of a value. Flag
  masks are written in hexadecimal.
- **Bit streams.** Compressed data (§6.3) is read most-significant-bit first:
  the first bit of the stream is bit 7 of its first byte.
- **Text.** Classic-container names are in an unspecified 8-bit code page
  (the creating system's OEM code page on DOS/Windows, usually UTF-8 on
  Unix), optionally accompanied by a Unicode form (§3.13). RAR 5.0 names are
  UTF-8. No string is NUL-terminated unless stated.
- **Alignment.** No structure is padded or aligned. Blocks follow each other
  byte-contiguously.
- **Terminology.** A *block* is a header plus its optional payload. An
  *entry* is a file or directory described by a file header. The *payload*
  (also *packed data*) is the stored or compressed bytes that follow a file
  header. The *window* (or *dictionary*) is the history of decompressed bytes
  that matches refer to. A *symbol* is one value decoded from a prefix code.
- **CRC-32** means the checksum of §6.1; "CRC16" means its low 16 bits
  (§6.2).

---

## 3. RAR 1.5–4.x container

### 3.1 Physical layout and signature discovery

An archive is: optional self-extractor (SFX) stub, the 7-byte marker, then a
contiguous sequence of blocks. The first block after the marker must be
MAIN_HEAD. The sequence normally ends with ENDARC_HEAD; archives written by
RAR versions before 3.0 may end without it, at end of file.

There is no central directory: entries are found by walking blocks from the
start.

**Signature discovery.** The marker `52 61 72 21 1A 07 00` is searched for
from the start of the file. RARLAB's documentation states that an SFX module
never contains the marker sequence itself, so the first occurrence is the
archive start. No maximum stub size is documented for the classic container;
the RAR 5.0 document says RAR assumes SFX modules of at most 1 MiB, and
readers commonly apply the same limit to both containers. Offsets inside the
archive (for example ENDARC volume data, or MAIN_HEAD's reserved position
fields) are not adjusted for the stub; a reader works relative to the
marker.

### 3.2 Common block header

Every block begins with:

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|--------|------|------|------|-----------------------|-------|
| 0 | 2 | u16 | HEAD_CRC | CRC16 of the header (§6.2) | Fixed `0x6152` for MARK_HEAD |
| 2 | 1 | u8 | HEAD_TYPE | Block type, §3.3 | |
| 3 | 2 | u16 | HEAD_FLAGS | Common bits below plus type-specific bits | |
| 5 | 2 | u16 | HEAD_SIZE | Header length in bytes, counted from offset 0, ≥ 7 | Includes every type-specific field, name and optional field |
| 7 | 4 | u32 | ADD_SIZE | Payload length; present only if `HEAD_FLAGS & 0x8000` | In FILE_HEAD and NEWSUB_HEAD this position is PACK_SIZE |

Common HEAD_FLAGS bits (valid in every block type):

| Mask | Name | Meaning |
|------|------|---------|
| `0x4000` | SKIP_IF_UNKNOWN | An archiver that does not know this block type drops it when updating the archive; if clear it copies the block. Has no meaning for readers. |
| `0x8000` | LONG_BLOCK | ADD_SIZE is present; the block is `HEAD_SIZE + ADD_SIZE` bytes long. Always set in FILE_HEAD. |

The remaining bits (`0x0001`–`0x2000`) are type-specific. Bits not defined
for a block type are reserved; readers ignore them.

### 3.3 Block types

| HEAD_TYPE | Name | Documented by | Payload length | Meaning |
|-----------|------|---------------|----------------|---------|
| `0x72` | MARK_HEAD | technote 1.5x–3.9x | none | The marker itself, readable as a block (§3.4) |
| `0x73` | MAIN_HEAD | technote | ADD_SIZE if LONG_BLOCK | Archive header, §3.5 |
| `0x74` | FILE_HEAD | technote | PACK_SIZE (+ HIGH_PACK_SIZE) | File or directory entry, §3.6 |
| `0x75` | COMMENT_HEAD | technote 1.5x–2.x | none | Old-style comment; exists only embedded in MAIN_HEAD or FILE_HEAD, §3.8 |
| `0x76` | AV_HEAD | technote ("old style authenticity information") | ADD_SIZE if LONG_BLOCK | Authenticity verification, RAR 2.x, §3.9 |
| `0x77` | SUB_HEAD | technote ("old style subblock") | ADD_SIZE if LONG_BLOCK | Old-style sub-block (OS/2 extended attributes, Unix owner, …), §3.9 |
| `0x78` | PROTECT_HEAD | technote ("old style recovery record") | ADD_SIZE if LONG_BLOCK | Recovery record, RAR 2.x, §3.9 |
| `0x79` | SIGN_HEAD | technote ("old style authenticity information") | ADD_SIZE if LONG_BLOCK | Authenticity signature, §3.9 |
| `0x7A` | NEWSUB_HEAD | technote ("subblock") | PACK_SIZE (+ HIGH_PACK_SIZE) | RAR 3.x service header with FILE_HEAD layout, §3.7 |
| `0x7B` | ENDARC_HEAD | not in technote 3.93 (§9, E1) | ADD_SIZE if LONG_BLOCK | End of archive, §3.10 |

Any other value is unknown. Unknown blocks are skipped by their length
(§3.3.1); refusing them is wrong because later RAR versions may add types.

#### 3.3.1 Walking the blocks

```
pos = markerOffset + 7
read MAIN_HEAD at pos                     -- must have HEAD_TYPE 0x73
pos = pos + MAIN_HEAD.HEAD_SIZE (+ ADD_SIZE if LONG_BLOCK)
while pos < fileLength:
    if fileLength - pos < 7: archive is truncated
    read HEAD_CRC, HEAD_TYPE, HEAD_FLAGS, HEAD_SIZE at pos
    if HEAD_SIZE < 7: header is malformed
    if HEAD_TYPE in {0x74, 0x7A}:
        payload = PACK_SIZE + (LHD_LARGE ? HIGH_PACK_SIZE << 32 : 0)
    else if HEAD_FLAGS & 0x8000:
        payload = ADD_SIZE
    else:
        payload = 0
    process the block
    if HEAD_TYPE == 0x7B: stop             -- nothing after ENDARC is read
    pos = pos + HEAD_SIZE + payload        -- 64-bit, overflow-checked
```

FILE_HEAD and NEWSUB_HEAD are always followed by their PACK_SIZE bytes. The
technote's processing outline uses PACK_SIZE for FILE_HEAD regardless of
LONG_BLOCK (which RAR always sets there anyway).

### 3.4 MARK_HEAD (0x72)

The 7-byte marker `52 61 72 21 1A 07 00` read as a block gives HEAD_CRC
`0x6152`, HEAD_TYPE `0x72`, HEAD_FLAGS `0x1A21`, HEAD_SIZE `0x0007`. The
"CRC" is not a checksum; readers compare the seven bytes literally.

### 3.5 MAIN_HEAD (0x73)

| Offset | Size | Type | Name | Meaning | Notes |
|--------|------|------|------|---------|-------|
| 0 | 7 | — | common header | HEAD_TYPE = `0x73` | HEAD_SIZE is 13 in RAR 3.x/4.x archives without extras |
| 7 | 2 | u16 | RESERVED1 | Zero; described elsewhere as the high part of the AV block position | Ignore |
| 9 | 4 | u32 | RESERVED2 | Zero; described elsewhere as the AV block position | Ignore |
| 13 | var | — | embedded comment | Present if MHD_COMMENT: a COMMENT_HEAD block (§3.8) | RAR ≤ 2.x only |
| … | var | — | further fields | Later RAR versions may add bytes up to HEAD_SIZE (§3.5.1) | Ignore |

MAIN_HEAD flags:

| Mask | Name | Meaning | Reader action |
|------|------|---------|---------------|
| `0x0001` | MHD_VOLUME | Archive is one volume of a multi-volume set | Needs the other volumes for split entries |
| `0x0002` | MHD_COMMENT | Old-style comment embedded in this header (RAR ≤ 2.x; RAR 3.x uses a NEWSUB "CMT" block instead) | Changes the HEAD_CRC span (§6.2) |
| `0x0004` | MHD_LOCK | Archive is locked against modification | Informational |
| `0x0008` | MHD_SOLID | Solid archive: entries may continue the previous entry's dictionary | See LHD_SOLID |
| `0x0010` | MHD_NEWNUMBERING | RAR 3.x: volumes are named `name.partN.rar`. Technote 1.5x lists this bit as unused. | Volume naming only |
| `0x0020` | MHD_AV | Authenticity information present (not set by RAR 3.x) | Informational |
| `0x0040` | MHD_PROTECT | Recovery record present | Informational |
| `0x0080` | MHD_PASSWORD | All headers after MAIN_HEAD are encrypted | Blocks cannot be walked without the password |
| `0x0100` | MHD_FIRSTVOLUME | First volume of a set (set by RAR 3.0 and later) | Volume handling |
| `0x0200`–`0x2000` | reserved | "reserved for internal use" | Ignore |

#### 3.5.1 Extra MAIN_HEAD bytes

Technote 3.93 describes MAIN_HEAD as exactly 13 bytes plus an optional
embedded comment, but reserves the other flag bits "for internal use", and
HEAD_SIZE governs the real length. Later RAR versions may use reserved bits
together with additional bytes after offset 13. A reader must take the
header length from HEAD_SIZE and ignore bytes it does not understand.

### 3.6 FILE_HEAD (0x74)

| Offset | Size | Type | Name | Meaning / range | Notes |
|--------|------|------|------|-----------------|-------|
| 0 | 7 | — | common header | HEAD_TYPE = `0x74`, LONG_BLOCK set | |
| 7 | 4 | u32 | PACK_SIZE | Low 32 bits of the payload length | Occupies the ADD_SIZE position |
| 11 | 4 | u32 | UNP_SIZE | Low 32 bits of the unpacked size | |
| 15 | 1 | u8 | HOST_OS | §5.1 | Selects the meaning of ATTR and the path separator |
| 16 | 4 | u32 | FILE_CRC | CRC-32 (§6.1) of the unpacked file | For a split entry, see §7.6 |
| 20 | 4 | u32 | FTIME | Modification time, MS-DOS format (§3.12) | Local wall-clock time |
| 24 | 1 | u8 | UNP_VER | Version needed to extract, `10 × major + minor` | Selects the algorithm, §5.3 |
| 25 | 1 | u8 | METHOD | `0x30`–`0x35`, §5.2 | Compression level only |
| 26 | 2 | u16 | NAME_SIZE | Byte length of FILE_NAME | Must fit inside HEAD_SIZE |
| 28 | 4 | u32 | ATTR | Host attributes, §5.1 | |
| 32 | 4 | u32 | HIGH_PACK_SIZE | High 32 bits of the payload length | Only if LHD_LARGE |
| 36 | 4 | u32 | HIGH_UNP_SIZE | High 32 bits of the unpacked size | Only if LHD_LARGE |
| 32 or 40 | NAME_SIZE | bytes | FILE_NAME | §3.13 | |
| … | 8 | bytes | SALT | Encryption salt | Only if LHD_SALT |
| … | var | — | EXT_TIME | §3.11 | Only if LHD_EXTTIME |
| … | var | — | further fields | Up to HEAD_SIZE | Ignore |

The fixed part is 32 bytes (40 with LHD_LARGE). The optional fields appear in
the order shown. RAR ≤ 2.x placed an embedded COMMENT_HEAD (§3.8) after the
name when LHD_COMMENT is set.

FILE_HEAD flags:

| Mask | Name | Meaning |
|------|------|---------|
| `0x0001` | LHD_SPLIT_BEFORE | Payload continues from the previous volume |
| `0x0002` | LHD_SPLIT_AFTER | Payload continues in the next volume |
| `0x0004` | LHD_PASSWORD | Payload is encrypted |
| `0x0008` | LHD_COMMENT | Old-style file comment embedded after the name (not set by RAR 3.x) |
| `0x0010` | LHD_SOLID | The entry's compressed stream continues the state left by the previous entry (RAR 2.0 and later) |
| `0x00E0` | LHD_WINDOWMASK | 3-bit field `(flags >> 5) & 7`: dictionary `64 KiB << n` for n = 0…6; n = 7 marks a directory (RAR 2.0 and later) |
| `0x0100` | LHD_LARGE | HIGH_PACK_SIZE and HIGH_UNP_SIZE present |
| `0x0200` | LHD_UNICODE | FILE_NAME carries a Unicode name (§3.13) |
| `0x0400` | LHD_SALT | SALT present |
| `0x0800` | LHD_VERSION | Entry is an older version of a file; RAR appends `;n` to the name when displaying it |
| `0x1000` | LHD_EXTTIME | EXT_TIME present |
| `0x2000` | — | Not documented; reserved |
| `0x4000` | SKIP_IF_UNKNOWN | Common bit, §3.2 |
| `0x8000` | LONG_BLOCK | Always set |

Dictionary field values:

| n | Bits 7 6 5 | Dictionary |
|---|------------|------------|
| 0 | 000 | 64 KiB |
| 1 | 001 | 128 KiB |
| 2 | 010 | 256 KiB |
| 3 | 011 | 512 KiB |
| 4 | 100 | 1 MiB |
| 5 | 101 | 2 MiB |
| 6 | 110 | 4 MiB |
| 7 | 111 | Entry is a directory |

### 3.7 NEWSUB_HEAD (0x7A)

RAR 3.x stores auxiliary data in service headers that reuse the FILE_HEAD
layout of §3.6 byte for byte (PACK_SIZE, UNP_SIZE, HOST_OS, a CRC of the
unpacked service data, UNP_VER, METHOD, NAME_SIZE, …). FILE_NAME holds the
service name; the payload holds the service data, which may itself be
compressed. Known names:

| Name | Content |
|------|---------|
| `CMT` | Archive comment (RAR 3.x replacement for MHD_COMMENT) |
| `ACL` | NTFS access-control list of the preceding file |
| `STM` | NTFS alternate data stream of the preceding file |
| `RR` | Recovery record |
| others | Further names exist for host-specific metadata (owner, extended attributes, authenticity); readers that do not know a name skip the block |

The four names listed are the ones RARLAB documents for RAR 5.0 service
headers (§4.9), which continue the RAR 3.x service mechanism.

A service header that describes the preceding file follows that file's
payload. Readers that do not use a service skip it by its PACK_SIZE (§3.3.1).
Service headers are never archive entries.

### 3.8 COMMENT_HEAD (0x75), embedded

Defined by technote 1.5x; RAR 3.x no longer writes it. It appears only
inside MAIN_HEAD (at offset 13, MHD_COMMENT) or inside FILE_HEAD after the
name (LHD_COMMENT), and its bytes are counted in the enclosing HEAD_SIZE.

| Offset | Size | Type | Name | Meaning |
|--------|------|------|------|---------|
| 0 | 2 | u16 | HEAD_CRC | CRC16 of offsets 2 … 12 (HEAD_TYPE through COMM_CRC) |
| 2 | 1 | u8 | HEAD_TYPE | `0x75` |
| 3 | 2 | u16 | HEAD_FLAGS | |
| 5 | 2 | u16 | HEAD_SIZE | 13 + length of the comment data |
| 7 | 2 | u16 | UNP_SIZE | Unpacked comment length |
| 9 | 1 | u8 | UNP_VER | Algorithm version of the comment data |
| 10 | 1 | u8 | METHOD | `0x30`–`0x35` |
| 11 | 2 | u16 | COMM_CRC | CRC16 of the unpacked comment |
| 13 | var | bytes | COMMENT | Comment data, possibly compressed |

### 3.9 Legacy blocks 0x76, 0x77, 0x78, 0x79

These blocks were written by RAR 2.x for authenticity verification, old
sub-blocks (extended attributes and similar host metadata) and recovery
records. RAR 3.x replaced
them with NEWSUB_HEAD services. Technote 3.93 only declares their type
codes. Their bodies are proprietary or obsolete; a reader needs only the
common header to skip them: `HEAD_SIZE`, plus `ADD_SIZE` when LONG_BLOCK is
set.

| HEAD_TYPE | Body | Reader action |
|-----------|------|---------------|
| `0x76` AV_HEAD | Opaque authenticity data inside HEAD_SIZE | Skip |
| `0x77` SUB_HEAD | Sub-block type and data; data length in ADD_SIZE | Skip |
| `0x78` PROTECT_HEAD | Recovery-record parameters; parity data in ADD_SIZE | Skip; repair is out of scope |
| `0x79` SIGN_HEAD | Signature data inside HEAD_SIZE | Skip |

### 3.10 ENDARC_HEAD (0x7B)

| Offset | Size | Type | Name | Meaning | Notes |
|--------|------|------|------|---------|-------|
| 0 | 7 | — | common header | HEAD_TYPE = `0x7B` | RAR 3.x writes flags `0x4000`, HEAD_SIZE 7: bytes `C4 3D 7B 00 40 07 00` |
| 7 | 4 | u32 | ARC_DATA_CRC | CRC-32 of the volume's data | Only if EARC_DATACRC |
| 7 or 11 | 2 | u16 | VOL_NUMBER | Zero-based volume number | Only if EARC_VOLNUMBER |

The optional fields and flags below are not described by technote 3.93; they
are what multi-volume archives written by RAR 3.x and later carry. Only
HEAD_SIZE is needed to read past the block.

| Mask | Name | Meaning |
|------|------|---------|
| `0x0001` | EARC_NEXT_VOLUME | Another volume follows |
| `0x0002` | EARC_DATACRC | ARC_DATA_CRC present |
| `0x0004` | EARC_REVSPACE | Space reserved for a later recovery record |
| `0x0008` | EARC_VOLNUMBER | VOL_NUMBER present |

Readers stop at ENDARC_HEAD; anything after it is not part of the archive.

### 3.11 EXT_TIME

Present after FILE_NAME (and SALT) when LHD_EXTTIME is set. It refines the
modification time and can add creation, last-access and archiving times.

| Offset | Size | Type | Name | Meaning |
|--------|------|------|------|---------|
| 0 | 2 | u16 | EXT_FLAGS | Four 4-bit groups: bits 12–15 mtime, 8–11 ctime, 4–7 atime, 0–3 arctime |
| 2 | var | — | records | One record per group whose bit 3 is set, in the order mtime, ctime, atime, arctime |

Group bits:

| Bit (within the 4-bit group) | Meaning |
|------------------------------|---------|
| 3 (`0x8`) | The time is present |
| 2 (`0x4`) | Add one second to the DOS time (DOS times have two-second resolution) |
| 0–1 (`0x3`) | `k` = number of sub-second bytes, 0…3 |

Record layout:

| Size | Field | Notes |
|------|-------|-------|
| 4 | DOS time (§3.12) | Absent for mtime, which uses FTIME |
| k | Sub-second bytes | The `k` most significant bytes of a 24-bit little-endian count of 100 ns units; the missing low-order bytes are zero |

Value of a present time:

```
fraction = 0
for j in 0 ..< k:                          -- bytes in stored order
    fraction = fraction | byte[j] << (8 * (3 - k + j))
time = dosTime + (bit2 ? 1 s : 0) + fraction × 100 ns
```

The largest fraction is 0xFFFFFF × 100 ns ≈ 1.68 s. EXT_TIME is 2 to 26
bytes long (flags, up to 3 mtime bytes, and three records of up to 7 bytes).
Groups with bit 3 clear have no record. Times are local wall-clock times,
like FTIME.

### 3.12 MS-DOS date and time

A 32-bit value; the high half is the date, the low half the time.

| Bits | Field | Range |
|------|-------|-------|
| 25–31 | Year − 1980 | 0–127 (1980–2107) |
| 21–24 | Month | 1–12 |
| 16–20 | Day | 1–number of days in that month |
| 11–15 | Hour | 0–23 |
| 5–10 | Minute | 0–59 |
| 0–4 | Second ÷ 2 | 0–29 |

No time zone is stored. A value whose fields are out of range does not
denote a time; readers should report "no time" rather than normalise it.

### 3.13 File names

FILE_NAME is NAME_SIZE bytes. For HOST_OS 0, 1 and 2 (MS-DOS, OS/2,
Windows) the path separator is `\`; for Unix and other hosts it is `/` and
`\` is an ordinary character.

1. **LHD_UNICODE clear.** The bytes are in the creating system's 8-bit
   character set, which is not recorded: typically the OEM code page
   (CP437 and relatives) for DOS/Windows hosts, UTF-8 for Unix hosts.
2. **LHD_UNICODE set, no zero byte in the field.** The whole field is
   UTF-8.
3. **LHD_UNICODE set, zero byte present.** The bytes before the first zero
   are the 8-bit name (as in case 1); the bytes after it are a compact
   encoding of the UTF-16 name, decoded as follows.

```
input:  oem[]   -- the 8-bit name
        enc[]   -- bytes after the zero
output: a sequence of UTF-16 code units

high = enc[0];  i = 1;  out = []
flagByte = 0;  flagsLeft = 0
while i < enc.count:
    if flagsLeft == 0:
        flagByte = enc[i]; i += 1; flagsLeft = 4
        if i >= enc.count: stop                 -- a flag byte with nothing after it
    op = flagByte >> 6;  flagByte = (flagByte << 2) & 0xFF;  flagsLeft -= 1
    switch op:
      0: need 1 byte b:       out += b
      1: need 1 byte b:       out += high × 256 + b
      2: need 2 bytes lo, hi: out += hi × 256 + lo
      3: need 1 byte n:
           if n & 0x80:
               need 1 byte c
               repeat (n & 0x7F) + 2 times, while out.count < oem.count:
                   out += high × 256 + ((oem[out.count] + c) mod 256)
           else:
               repeat n + 2 times, while out.count < oem.count:
                   out += oem[out.count]
    -- "need" stops decoding when enc has too few bytes left
```

Opcode 3 copies characters from the 8-bit name at the same position as the
character being produced, which makes names that differ from their 8-bit
form in only a few characters cheap to encode.

Names are untrusted (§8): they may be absolute, contain `..` components or a
drive prefix, and may contain characters that are invalid on the reading
system.

---

## 4. RAR 5.0 container

This section restates RARLAB's published "RAR 5.0 archive format"
description in the structure of this document. It also applies to archives
written by RAR 6.x and 7.x.

### 4.1 Layout

In order: optional SFX module; the 8-byte signature
`52 61 72 21 1A 07 01 00`; an optional archive encryption header; the main
archive header; an optional archive comment service header; file headers,
each optionally followed by service headers that belong to it; an optional
recovery record; the end of archive header. The signature is searched for
from the start of the file over at most the maximum SFX size (currently
1 MiB).

### 4.2 vint

An unsigned integer stored 7 bits per byte, least significant group first.
Bit 7 of each byte is set when another byte follows.

```
value = 0; shift = 0
repeat:
    b = next byte
    value = value | (b & 0x7F) << shift
    shift += 7
until b & 0x80 == 0
```

At most 10 bytes encode a 64-bit value. A writer may reserve space by
emitting `0x80` continuation bytes that contribute zero bits, so non-minimal
encodings are legal. Examples: `00` = 0; `7F` = 127; `80 01` = 128;
`AC 02` = 300; `80 80 00` = 0.

### 4.3 General block header

| Field | Type | Meaning |
|-------|------|---------|
| Header CRC32 | u32 | CRC-32 of everything from "Header size" through the end of the extra area |
| Header size | vint | Bytes from "Header type" through the end of the extra area; at most 3 vint bytes (2 MiB) |
| Header type | vint | 1 main, 2 file, 3 service, 4 archive encryption, 5 end of archive |
| Header flags | vint | Table below |
| Extra area size | vint | Present if flag `0x0001` |
| Data size | vint | Present if flag `0x0002` |
| type-specific fields | … | §4.4–§4.8 |
| Extra area | bytes | The last "Extra area size" bytes of the header; present if `0x0001` |
| Data area | bytes | "Data size" bytes immediately after the header; not covered by Header CRC32 or Header size |

The header occupies `4 + len(Header size vint) + Header size` bytes. The next
block starts after the data area.

| Header flag | Meaning |
|-------------|---------|
| `0x0001` | Extra area present |
| `0x0002` | Data area present |
| `0x0004` | When updating, skip a block of unknown type that has this flag |
| `0x0008` | Data area continues from the previous volume |
| `0x0010` | Data area continues in the next volume |
| `0x0020` | Block depends on the preceding file block |
| `0x0040` | When the host block is modified, preserve this child block |

**Extra area records.** The extra area is a sequence of records:

| Field | Type | Meaning |
|-------|------|---------|
| Size | vint | Bytes from "Type" to the end of the record |
| Type | vint | Record type (meaning depends on the header type) |
| Data | bytes | `Size − len(Type)` bytes; may be empty |

Unknown record types are skipped.

### 4.4 Archive encryption header (type 4)

| Field | Type | Meaning |
|-------|------|---------|
| Encryption version | vint | 0 = AES-256 (only value defined) |
| Encryption flags | vint | `0x0001` = check value present |
| KDF count | u8 | log2 of the PBKDF2 iteration count |
| Salt | 16 bytes | Salt for all header keys |
| Check value | 12 bytes | Present if `0x0001`: 8 bytes derived by extra PBKDF2 iterations plus a 4-byte checksum; lets a reader tell a wrong password from damage |

Every following header is preceded by a 16-byte AES-256 IV and stored
encrypted, padded to a multiple of 16 bytes.

### 4.5 Main archive header (type 1)

| Field | Type | Meaning |
|-------|------|---------|
| Archive flags | vint | Table below |
| Volume number | vint | Present if `0x0002`: 1 for the second volume, 2 for the third, …; absent in the first volume |
| Extra area | | Records below |

| Archive flag | Meaning |
|--------------|---------|
| `0x0001` | Archive is a volume |
| `0x0002` | Volume number field present (every volume but the first) |
| `0x0004` | Solid archive |
| `0x0008` | Recovery record present |
| `0x0010` | Locked archive |

Main-header extra records:

| Type | Name | Data |
|------|------|------|
| `0x01` | Locator | Flags vint (`0x0001` quick-open offset present, `0x0002` recovery-record offset present); quick-open offset vint; recovery-record offset vint. Offsets are distances from the start of the main header forward to the respective block; 0 means "ignore". |
| `0x02` | Metadata | Flags vint (`0x0001` name present, `0x0002` creation time present, `0x0004` Unix time (else Windows FILETIME), `0x0008` Unix time in nanoseconds); name length vint and UTF-8 name (truncate at the first zero; a leading zero means no name); time: 8-byte FILETIME, or 4-byte Unix seconds, or 8-byte Unix nanoseconds |

### 4.6 File header (type 2) and service header (type 3)

| Field | Type | Meaning |
|-------|------|---------|
| File flags | vint | Table below |
| Unpacked size | vint | Size of the unpacked file or service data; ignore if `0x0008` |
| Attributes | vint | Host attributes (file); 0 or reserved (service) |
| mtime | u32 | Unix time in seconds; present if `0x0002` |
| Data CRC32 | u32 | Present if `0x0004`; CRC-32 of the unpacked data, or for a non-final split part of the packed data in this volume |
| Compression information | vint | §4.6.1 |
| Host OS | vint | 0 Windows, 1 Unix |
| Name length | vint | |
| Name | bytes | UTF-8, no terminator; `/` separates path components for both hosts. For service headers, the service name (§4.9). |
| Extra area | | §4.7 |
| Data area | | The packed file or service data (length = header's Data size) |

| File flag | Meaning |
|-----------|---------|
| `0x0001` | Directory (file headers only) |
| `0x0002` | mtime field present |
| `0x0004` | Data CRC32 field present |
| `0x0008` | Unpacked size unknown: decompress to the end of the stream |

Unix names that contained bytes not convertible to Unicode store those bytes
as U+E080…U+E0FF and include a U+FFFE marker. On Windows hosts `\` is
invalid in names; on Unix hosts it is an ordinary character.

#### 4.6.1 Compression information

| Mask | Field |
|------|-------|
| `0x0000003F` | Algorithm version: 0 = RAR 5.0, 1 = RAR 7.0; other values undefined |
| `0x00000040` | Solid: continue the previous file's compression state (file headers only) |
| `0x00000380` | Method `(v >> 7) & 7`: 0 = stored, 1–5 = fastest…best |
| `0x00007C00` | `N = (v >> 10) & 0x1F`: minimum dictionary `128 KiB << N`, N = 0…23 (128 KiB…1 TiB); N > 15 requires version 1 |
| `0x000F8000` | Version 1 only: `F = (v >> 15) & 0x1F`; dictionary += F × dictionary / 32 |
| `0x00100000` | Version 1 only: the data is really version 0, used when version-1 files are appended to a version-0 solid stream |

### 4.7 File and service extra records

| Type | Name | Data |
|------|------|------|
| `0x01` | File encryption | Version vint (0 = AES-256); flags vint (`0x0001` check value present, `0x0002` "tweaked" checksums: the CRC32 and hash depend on the key); KDF count u8 (log2 of PBKDF2 iterations); salt 16 bytes; IV 16 bytes; check value 12 bytes if `0x0001` |
| `0x02` | File hash | Hash type vint (0 = BLAKE2sp); hash data (32 bytes for BLAKE2sp). Covers the unpacked data, or for a non-final split part the packed data in this volume |
| `0x03` | File time | Flags vint (`0x0001` Unix time_t format, else Windows FILETIME; `0x0002` mtime, `0x0004` ctime, `0x0008` atime present; `0x0010` Unix times have nanosecond fields); then mtime, ctime, atime as u32 (Unix) or u64 (FILETIME) for each present time; then a u32 nanosecond field for each present time when `0x0001` and `0x0010` are set |
| `0x04` | File version | Flags vint (none defined); version number vint |
| `0x05` | Redirection | Type vint (1 Unix symlink, 2 Windows symlink, 3 Windows junction, 4 hard link, 5 file copy); flags vint (`0x0001` target is a directory); name length vint; UTF-8 target name |
| `0x06` | Unix owner | Flags vint (`0x0001` user name, `0x0002` group name, `0x0004` numeric UID, `0x0008` numeric GID present); user name length vint + bytes; group name length vint + bytes; UID vint; GID vint (each only if flagged) |
| `0x07` | Service data | Service-specific bytes (service headers only) |

Windows FILETIME counts 100 ns intervals since 1601-01-01 UTC.

### 4.8 End of archive header (type 5)

| Field | Type | Meaning |
|-------|------|---------|
| End of archive flags | vint | `0x0001`: archive is a volume and not the last one |

RAR reads nothing after this header; tools may append data after it.

### 4.9 Service headers

| Name | Placement | Content |
|------|-----------|---------|
| `CMT` | After the main header, before file headers | Archive comment, UTF-8, stored (method 0, packed = unpacked size) |
| `QO` | After all file headers, before the recovery record and end header | Quick-open cache (§4.9.1) |
| `ACL` | After its file | NTFS permissions |
| `STM` | After its file | NTFS alternate data stream |
| `RR` | Before the end header | Recovery record (structure not published) |

#### 4.9.1 Quick-open data

The stored data of the `QO` service is a sequence of cache records:

| Field | Type | Meaning |
|-------|------|---------|
| Structure CRC32 | u32 | CRC-32 from "Structure size" to the end of the record |
| Structure size | vint | Bytes from "Flags" to the end; at most 3 vint bytes |
| Flags | vint | 0 |
| Offset | vint | Distance from the start of the quick-open header to the cached data's original position; increasing through the list |
| Data size | vint | |
| Data | bytes | Copy of archive bytes (usually headers) at that position |

A reader must use quick-open data for both listing and extraction or for
neither; otherwise a crafted archive can list one name and extract another.

### 4.10 RAR 5.0 compression

The RAR 5.0 and RAR 7.0 compressed bitstreams (LZ77 with Huffman tables,
built-in filters for x86, ARM and delta data) are not published by RARLAB and
are not specified in this document.

---

## 5. Enumerations

### 5.1 HOST_OS (classic container)

| Value | Host | ATTR meaning | Path separator |
|-------|------|--------------|----------------|
| 0 | MS-DOS | DOS attributes (`0x01` read-only, `0x02` hidden, `0x04` system, `0x10` directory, `0x20` archive) | `\` |
| 1 | OS/2 | DOS attributes | `\` |
| 2 | Win32 | Windows attributes (DOS bits plus e.g. `0x80` normal, `0x400` reparse point, `0x800` compressed) | `\` |
| 3 | Unix | `st_mode` (file type in `0o170000`: `0o040000` directory, `0o100000` regular, `0o120000` symbolic link) | `/` |
| 4 | Mac OS | Host-specific | `/` |
| 5 | BeOS | Host-specific | `/` |
| other | unknown | Uninterpreted | `/` |

RAR 5.0 uses Host OS 0 (Windows attributes) and 1 (Unix `st_mode`).

### 5.2 METHOD (classic container)

| Value | Name | Payload |
|-------|------|---------|
| `0x30` | Store | The file bytes; `PACK_SIZE == UNP_SIZE` unless encrypted (then padded to 16 bytes) |
| `0x31` | Fastest | Compressed with the algorithm named by UNP_VER |
| `0x32` | Fast | 〃 |
| `0x33` | Normal (default) | 〃 |
| `0x34` | Good | 〃 |
| `0x35` | Best | 〃 |
| other | — | Undefined |

The level does not change the bitstream format; a reader dispatches on
UNP_VER.

### 5.3 UNP_VER

| Value | Algorithm | Notes |
|-------|-----------|-------|
| 15 | RAR 1.5 | |
| 20 | RAR 2.0 | |
| 26 | RAR 2.0 algorithm | Version number used for entries that need large-file support |
| 29 | RAR 2.9 | RAR/WinRAR 3.x–4.x, §6.3 |
| 36 | RAR 2.9 algorithm | Treated as 29; not present in the archives SwiftRAR was validated against |
| other | unknown | Extractors report the entry as unsupported |

For stored entries UNP_VER only states the minimum RAR version; the payload
is the file itself whatever the value.

### 5.4 Dictionary sizes

Classic container: §3.6 table (64 KiB to 4 MiB). RAR 5.0: §4.6.1.

### 5.5 Summary of type codes

| Container | Field | Values |
|-----------|-------|--------|
| Classic | HEAD_TYPE | `0x72`–`0x7B`, §3.3 |
| Classic | NEWSUB names | §3.7 |
| RAR 5.0 | Header type | 1–5, §4.3 |
| RAR 5.0 | Main extra records | 1–2, §4.5 |
| RAR 5.0 | File/service extra records | 1–7, §4.7 |
| RAR 5.0 | Redirection types | 1–5, §4.7 |
| RAR 5.0 | Service names | §4.9 |

---

## 6. Algorithms

### 6.1 CRC-32

The classic container (FILE_CRC, header CRC16), RAR 5.0 headers and RAR 5.0
data CRCs all use the same CRC:

| Parameter | Value |
|-----------|-------|
| Width | 32 |
| Polynomial | `0x04C11DB7` (reflected form `0xEDB88320`) |
| Initial value | `0xFFFFFFFF` |
| Input / output reflected | yes / yes |
| Final XOR | `0xFFFFFFFF` |
| Check value (`"123456789"`) | `0xCBF43926` |

This is the CRC of ZIP, gzip and PNG (catalogued as CRC-32/ISO-HDLC).

```
table[n] for n in 0…255:
    c = n
    repeat 8 times: c = (c >> 1) XOR (0xEDB88320 if c & 1 else 0)
    table[n] = c

crc32(bytes):
    c = 0xFFFFFFFF
    for b in bytes: c = table[(c XOR b) & 0xFF] XOR (c >> 8)
    return c XOR 0xFFFFFFFF
```

### 6.2 Classic header CRC16

HEAD_CRC is `crc32(span) & 0xFFFF`, where the span starts at HEAD_TYPE
(offset 2) and normally ends at HEAD_SIZE (the whole header except the CRC
field itself). The payload is never covered. Check value: `"123456789"` →
`0x3926`. Example: ENDARC_HEAD bytes `7B 00 40 07 00` → `0x3DC4`.

| Block | Span | Source |
|-------|------|--------|
| MARK_HEAD | none (fixed `0x6152`) | technote |
| MAIN_HEAD without MHD_COMMENT | offsets 2 … HEAD_SIZE−1 | technote ("HEAD_TYPE to RESERVED2"; HEAD_SIZE is 13) |
| MAIN_HEAD with MHD_COMMENT | offsets 2 … 12 (fixed part only) | technote: the CRC covers HEAD_TYPE to RESERVED2, the embedded comment has its own CRC |
| FILE_HEAD | offsets 2 … HEAD_SIZE−1, including SALT and EXT_TIME | technote names "HEAD_TYPE to FILEATTR and file name"; RAR 3.x archives also cover SALT and EXT_TIME (§9, E3) |
| FILE_HEAD with LHD_COMMENT (RAR ≤ 2.x) | offsets 2 … end of FILE_NAME | technote text; the embedded comment has its own CRC |
| NEWSUB_HEAD | as FILE_HEAD | same layout as FILE_HEAD |
| COMMENT_HEAD | offsets 2 … 12 | technote 1.5x |
| ENDARC_HEAD | offsets 2 … HEAD_SIZE−1 | observed in RAR 3.x archives |
| AV_HEAD, SUB_HEAD, PROTECT_HEAD, SIGN_HEAD, unknown | not specified | — |

### 6.3 RAR 2.9 compressed stream

Used by entries with UNP_VER 29 or 36 and METHOD `0x31`–`0x35`. The payload
of such an entry is one bit stream that produces exactly UNP_SIZE bytes.

#### 6.3.1 Bit input

The stream is consumed most-significant-bit first. `bits(n)` returns the
next `n` bits as an unsigned integer whose first bit is its most significant
bit. `align()` discards the rest of the current byte (nothing if already at
a byte boundary). Readers need `n` up to 16.

#### 6.3.2 Decoder state

| State | Initial value | Lifetime |
|-------|---------------|----------|
| output / window | empty | Entry (whole solid group in solid archives) |
| `prevLengths[404]` | all 0 | Stream (§6.3.5) |
| four prefix codes | none | Until the next table read |
| `recent[0…3]` | 0, 0, 0, 0 | Stream |
| `lastLength` | 0 | Stream |
| `lowValue` | 0 | Stream; set to 0 by every table read |
| `lowRepeat` | 0 | Stream; set to 0 by every table read |
| `tablesValid` | false | Stream |

"Stream" means: reset when a non-solid entry starts, kept across entries of a
solid group (§6.3.11).

#### 6.3.3 Block header

Whenever tables are needed (`tablesValid` false at the start of an entry, or
after an end-of-block marker that requests them) the decoder reads a block
header:

```
align()
if bits(1) == 1: this is a PPMd block (§6.3.10)
keep = bits(1)
if keep == 0: prevLengths = all 0
read the tables (§6.3.5)
lowValue = 0; lowRepeat = 0
tablesValid = true
```

#### 6.3.4 Prefix codes

Every alphabet is coded with a canonical prefix code defined only by a code
length per symbol (0 = unused, 1…15 = length in bits):

1. Count the symbols of each length 1…15.
2. Codes of length `L` start at `first[L] = (first[L−1] + count[L−1]) << 1`
   with `first[1] = 0` and `count[0] = 0`.
3. Within one length, symbols receive consecutive codes in increasing symbol
   order.

This is the same assignment DEFLATE uses (RFC 1951 §3.2.2). Codes are read
most-significant-bit first, one bit at a time conceptually:

```
code = 0; first = 0; index = 0
for L in 1…15:
    code = code | bits(1)
    if code − first < count[L]: return sortedSymbols[index + code − first]
    index += count[L]; first = (first + count[L]) << 1; code = code << 1
the bits do not form a code → the stream is corrupt
```

`sortedSymbols` lists the used symbols ordered by (length, symbol). A code
may be incomplete (the Kraft sum is below 1): real encoders produce such
codes, and only bit patterns outside the code are errors. A code whose Kraft
sum exceeds 1 is invalid.

#### 6.3.5 Table transmission

**Pre-code.** Twenty 4-bit values give the code lengths of the 20-symbol
pre-code alphabet:

```
i = 0
while i < 20:
    v = bits(4)
    if v == 15:
        z = bits(4)
        if z == 0: preLength[i] = 15; i += 1
        else: set min(z + 2, 20 − i) entries starting at i to 0; advance i past them
    else:
        preLength[i] = v; i += 1
```

**Main lengths.** The pre-code then yields 404 code lengths, for the four
alphabets in the order of §6.3.6:

```
i = 0
while i < 404:
    s = decode with the pre-code
    if s <= 15:
        lengths[i] = (s + prevLengths[i]) & 15; i += 1
    else if s == 16 or s == 17:
        n = (s == 16) ? bits(3) + 3 : bits(7) + 11
        if i == 0: corrupt                       -- nothing to repeat
        repeat n times while i < 404: lengths[i] = lengths[i − 1]; i += 1
    else:                                        -- 18 or 19
        n = (s == 18) ? bits(3) + 3 : bits(7) + 11
        repeat n times while i < 404: lengths[i] = 0; i += 1
prevLengths = lengths
```

Runs that would pass 404 are cut at 404. Delta coding (`s + prevLengths[i]`)
only matters when the keep bit was set; otherwise `prevLengths` is zero.

#### 6.3.6 Alphabets

| Order | Name | Size | Range within the 404 lengths | Purpose |
|-------|------|------|------------------------------|---------|
| 1 | main | 299 | 0–298 | Literals, matches, control symbols |
| 2 | distance slot | 60 | 299–358 | Slot of a new match distance |
| 3 | low distance | 17 | 359–375 | Low 4 bits of large distances, or "repeat" |
| 4 | length | 28 | 376–403 | Length code after a recent-distance symbol |

Main alphabet:

| Symbol | Meaning |
|--------|---------|
| 0–255 | Literal byte |
| 256 | End of block (§6.3.8) |
| 257 | Filter record (§6.3.9) |
| 258 | Repeat the previous match |
| 259–262 | Match at `recent[symbol − 259]`, length from the length alphabet |
| 263–270 | Two-byte match at a short distance |
| 271–298 | Match with an explicit distance, length code `symbol − 271` |

#### 6.3.7 Static tables

Length codes (used by symbols 259–262 via the length alphabet and by
271–298). `base` and `extra` give the length contribution and the number of
raw bits that follow:

| Code | base | extra | | Code | base | extra |
|------|------|-------|-|------|------|-------|
| 0 | 0 | 0 | | 14 | 24 | 2 |
| 1 | 1 | 0 | | 15 | 28 | 2 |
| 2 | 2 | 0 | | 16 | 32 | 3 |
| 3 | 3 | 0 | | 17 | 40 | 3 |
| 4 | 4 | 0 | | 18 | 48 | 3 |
| 5 | 5 | 0 | | 19 | 56 | 3 |
| 6 | 6 | 0 | | 20 | 64 | 4 |
| 7 | 7 | 0 | | 21 | 80 | 4 |
| 8 | 8 | 1 | | 22 | 96 | 4 |
| 9 | 10 | 1 | | 23 | 112 | 4 |
| 10 | 12 | 1 | | 24 | 128 | 5 |
| 11 | 14 | 1 | | 25 | 160 | 5 |
| 12 | 16 | 2 | | 26 | 192 | 5 |
| 13 | 20 | 2 | | 27 | 224 | 5 |

Codes 0–7 have no extra bits; from code 8 on, every group of four codes
doubles the step. The largest coded value is 224 + 31 = 255.

Distance slots: 60 slots, each with a base and a number of extra bits. They
are generated from the number of slots per extra-bit count:

```
slotsPerExtra = [4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 14, 0, 12]
                -- index = number of extra bits (0 … 18)
base = 0; slot = 0
for extra in 0…18:
    repeat slotsPerExtra[extra] times:
        slotBase[slot] = base; slotExtra[slot] = extra
        base += 1 << extra; slot += 1
```

| Slots | extra | First base | Step |
|-------|-------|------------|------|
| 0–3 | 0 | 0 | 1 |
| 4–5 | 1 | 4 | 2 |
| 6–7 | 2 | 8 | 4 |
| 8–9 | 3 | 16 | 8 |
| 10–11 | 4 | 32 | 16 |
| 12–13 | 5 | 64 | 32 |
| 14–15 | 6 | 128 | 64 |
| 16–17 | 7 | 256 | 128 |
| 18–19 | 8 | 512 | 256 |
| 20–21 | 9 | 1 024 | 512 |
| 22–23 | 10 | 2 048 | 1 024 |
| 24–25 | 11 | 4 096 | 2 048 |
| 26–27 | 12 | 8 192 | 4 096 |
| 28–29 | 13 | 16 384 | 8 192 |
| 30–31 | 14 | 32 768 | 16 384 |
| 32–33 | 15 | 65 536 | 32 768 |
| 34–47 | 16 | 131 072 | 65 536 |
| 48–59 | 18 | 1 048 576 | 262 144 |

The last slot ends at 4 194 304 = 4 MiB, the largest window.

Short distances (symbols 263–270, index `k = symbol − 263`):

| k | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| base | 0 | 4 | 8 | 16 | 32 | 64 | 128 | 192 |
| extra | 2 | 2 | 3 | 4 | 5 | 6 | 6 | 6 |

Together they cover distances 1…256.

#### 6.3.8 Decoding loop

All distances below are "bytes back from the next output position" and are at
least 1. `copy(length, distance)` appends `length` bytes, each equal to the
byte `distance` positions before it; when `distance < length` the copy
overlaps itself and repeats a pattern, so it must proceed byte by byte (or
equivalently).

```
push(d):  recent[3] = recent[2]; recent[2] = recent[1]; recent[1] = recent[0]; recent[0] = d

while output.count < UNP_SIZE:
    if not tablesValid: read a block header (§6.3.3)
    s = decode(main)

    if s < 256:
        append byte s

    else if s >= 271:                                   -- explicit match
        c = s − 271
        length = lengthBase[c] + 3 + bits(lengthExtra[c])
        slot = decode(distance slot)
        d = slotBase[slot] + 1
        e = slotExtra[slot]
        if e > 0 and slot <= 9:
            d += bits(e)
        else if e > 0:                                  -- slots 10…59, e >= 4
            if e > 4: d += bits(e − 4) << 4
            if lowRepeat > 0:
                lowRepeat −= 1; d += lowValue
            else:
                v = decode(low distance)
                if v == 16: lowRepeat = 15; d += lowValue
                else:       lowValue = v; d += v
        if d >= 0x2000:  length += 1
        if d >= 0x40000: length += 1
        push(d); lastLength = length
        copy(length, d)

    else if s == 256:                                   -- end of block, §6.3.8.1
        ...

    else if s == 257:                                   -- filter record, §6.3.9
        ...

    else if s == 258:                                   -- repeat previous match
        if lastLength != 0: copy(lastLength, recent[0])

    else if s <= 262:                                   -- recent distance
        k = s − 259
        d = recent[k]
        move recent[k] to the front: recent[k..1] = recent[k−1..0]; recent[0] = d
        c = decode(length)
        length = lengthBase[c] + 2 + bits(lengthExtra[c])
        lastLength = length
        copy(length, d)

    else:                                               -- 263…270, short match
        k = s − 263
        d = shortBase[k] + 1 + bits(shortExtra[k])
        push(d); lastLength = 2
        copy(2, d)
```

Notes:

- The bonus `+1`/`+2` for distances ≥ `0x2000` and ≥ `0x40000` applies only
  to explicit matches (271–298). Recent-distance matches (259–262) and the
  repeat symbol (258) carry no bonus.
- `push` does not remove an existing copy of `d`; the history may hold
  duplicates. Only symbols 259–262 move an entry to the front.
- Explicit-match lengths therefore range from 3 to 260, recent-distance
  lengths from 2 to 257, short matches are always 2.
- A recent-distance symbol whose history slot is still 0, or any distance
  larger than the bytes produced so far for the stream, is corrupt in a
  non-solid entry.

##### 6.3.8.1 End of block

After symbol 256 the decoder reads one or two bits:

| Bits | Meaning |
|------|---------|
| `1` | Another block of this entry follows; read a new block header (§6.3.3) immediately. |
| `0 0` | The entry's data ends here. In a solid group the next entry continues with the current tables. |
| `0 1` | The entry's data ends here. In a solid group the next entry starts with a block header (`tablesValid = false`). |

An entry may also end without symbol 256: the decoder stops as soon as
UNP_SIZE bytes have been produced, and any remaining payload bits are
ignored. If the data ends (by `0 0`/`0 1`) before UNP_SIZE bytes exist, the
entry is corrupt.

#### 6.3.9 Filter records

Symbol 257 introduces a filter record: the instruction to post-process a
range of the output with one of the RAR 2.9 virtual-machine programs
(standard programs for x86 call/jump targets ("E8", "E8E9"), Itanium
branches, byte deltas, 24/32-bit images ("RGB") and audio, or an arbitrary
program). The window keeps the unfiltered bytes; the filtered result is what
is written to the file.

Record framing:

```
first = bits(8)
n = first & 7
size = n + 1          if n <= 5         -- 1…6 bytes
size = bits(8) + 7    if n == 6         -- 7…262 bytes
size = bits(16)       if n == 7
record = size bytes, each read with bits(8)
```

The upper bits of `first` and the record bytes describe which filter to run,
the output range, and optional program bytecode, registers and global data.
That content and the virtual machine are outside the scope of this
document.

#### 6.3.10 PPMd blocks

A block header whose first bit is 1 starts a block coded with Dmitry
Shkarin's PPMd (variant H) and a range coder instead of the LZ alphabets. It
continues with model parameters, and inside the block an escape byte
introduces commands (end of the PPMd block, end of the entry, filter
records, and LZ-style matches). A PPMd block ends with a return to LZ mode,
which reads a new block header. PPMd blocks are not specified further here.

#### 6.3.11 Window and solid groups

The window is the history of output bytes that matches may reach: up to the
dictionary size in FILE_HEAD bits 5–7 (at most 4 MiB). In a non-solid entry
no distance may exceed the number of bytes produced for that entry.

In a solid archive, an entry with LHD_SOLID continues the stream of the
previous entry: the window, `recent`, `lastLength`, `lowValue`, `lowRepeat`,
`prevLengths`, the prefix codes and `tablesValid` all carry over, and matches
may reach into earlier entries' output. Extracting such an entry requires
decoding every preceding entry of the group in archive order. Each entry
still produces exactly its own UNP_SIZE bytes, checked against its own
FILE_CRC.

### 6.4 Other compressed formats

RAR 1.5 (UNP_VER 15), RAR 2.0 (20, 26) and the RAR 5.0/7.0 algorithms use
bitstreams that differ from §6.3 (different alphabets, tables and control
symbols). They are not specified in this document.

### 6.5 Encryption

| Container | Cipher | Key derivation |
|-----------|--------|----------------|
| Classic, RAR 2.0 | Proprietary RAR 2.0 cipher | Proprietary |
| Classic, RAR 3.x–4.x | AES-128 in CBC mode | Iterated SHA-1 over the password (UTF-16LE) and the 8-byte SALT (2^18 rounds) yields key and IV |
| RAR 5.0 | AES-256 in CBC mode | PBKDF2-HMAC-SHA256 with 2^KDF count iterations and a 16-byte salt (§4.4, §4.7) |

Details are outside the scope of this document; an extractor without
encryption support reports encrypted entries and header-encrypted archives
as unsupported.

---

## 7. Semantics and de-facto behaviour

### 7.1 Directory entries

In the classic container an entry is a directory when the dictionary field
of HEAD_FLAGS is 7 (`flags & 0xE0 == 0xE0`). Its PACK_SIZE and UNP_SIZE are
0. RAR 1.5 predates the dictionary field; directories in such archives are
identifiable only through ATTR (DOS attribute `0x10`). In RAR 5.0 the file
flag `0x0001` marks directories.

### 7.2 Order and duplicates

Entries appear in the order the archiver wrote them, typically a directory
after or before its contents with no guarantee either way. The same name may
appear more than once (for example with LHD_VERSION). Readers must not
assume uniqueness.

### 7.3 Path separators

DOS-family hosts (HOST_OS 0–2) store `\`; readers presenting POSIX-style
paths convert it to `/` for those hosts only. On Unix hosts `\` is a literal
character.

### 7.4 Missing ENDARC_HEAD

Archives created before RAR 3.0 do not end with ENDARC_HEAD. Reaching end of
file exactly at a block boundary is a normal end of archive. Ending inside a
header or payload is truncation.

### 7.5 Stored entries

A stored, unencrypted entry has `PACK_SIZE == UNP_SIZE`. The FILE_CRC check
applies as for compressed entries. Stored data does not pass through the
decompression state.

### 7.6 Split entries

In a volume set an entry whose payload crosses a volume boundary has
LHD_SPLIT_AFTER in the first part and LHD_SPLIT_BEFORE in the following
parts. Only the final part's FILE_CRC can be relied on to be the CRC-32 of
the whole unpacked file; for RAR 5.0, RARLAB documents that non-final parts
carry a CRC of their packed data instead (§4.6). A part on its own is never a
complete entry.

### 7.7 Timestamps

FTIME and EXT_TIME are local wall-clock times of the creating machine with no
time zone. Software that needs an absolute instant has to assume one (for
example UTC or the reader's own zone). RAR 5.0 times are absolute (Unix time
or FILETIME, both UTC).

### 7.8 LHD_LARGE

The flag is set when a size does not fit in 32 bits. Readers combine the
words as `HIGH << 32 | LOW` whenever the flag is set, regardless of the
values.

### 7.9 Observed writer behaviour (WinRAR 3.x)

The following were observed in archives written by WinRAR 3.x and confirmed
by comparing against independent extractors (§11.2):

- MAIN_HEAD is exactly 13 bytes with flags `0x0000` (non-solid) and a valid
  CRC16 over the whole header.
- Every FILE_HEAD has LONG_BLOCK set and a CRC16 over the whole header,
  including EXT_TIME.
- ENDARC_HEAD is written as `C4 3D 7B 00 40 07 00`.
- Compressed entries end when UNP_SIZE bytes have been produced: none of the
  238 compressed entries in the validation corpus (§11.2) ends with symbol
  256.
- Long entries are split into several LZ blocks; every one of the 152
  in-entry table refreshes in the corpus sets the keep bit (delta coding
  against the previous lengths, §6.3.5).
- Recent-distance matches (symbols 259–262) take no length bonus: the corpus
  contains 4 321 of them at distances ≥ `0x101` (498 at ≥ `0x2000`), and the
  output matches the reference extraction only without a bonus.

---

## 8. Robustness guidance for readers

Every field of an archive is untrusted. Recommended checks:

| Concern | Guidance |
|---------|----------|
| Signature search | Bound the search (1 MiB plus the signature length). |
| HEAD_SIZE | Reject values below 7, below the fixed size of the block type (13 MAIN, 32/40 FILE and NEWSUB), or beyond the end of the input. A zero HEAD_SIZE would stall a naive walker. |
| NAME_SIZE, optional fields | Must fit inside HEAD_SIZE; otherwise the header is malformed. |
| PACK_SIZE / ADD_SIZE | 64-bit, overflow-checked addition; the payload must lie inside the input. |
| UNP_SIZE | Archive-controlled. Never pre-allocate it blindly; cap output at it and let callers impose their own limit. On 32-bit platforms it may not be addressable. |
| Header CRC | Verify where §6.2 defines a span; a mismatch means the header cannot be trusted. |
| Decompression | Every table read must stay in bounds; reject over-subscribed codes and repeat-previous at index 0; reject distances of 0 or beyond the produced output; stop at UNP_SIZE; treat end of input before UNP_SIZE bytes as truncation; verify FILE_CRC afterwards. The output loop must make progress per symbol, so it terminates. |
| Compact UTF-16 names | Bound every index by the input lengths and the output by the 8-bit name length (opcode 3) and the encoded length. |
| EXT_TIME | Every record must fit inside HEAD_SIZE. |
| Names | Treat as hostile: strip drive prefixes and leading separators, reject `..`, and do not follow symbolic-link entries when extracting. |
| Contradictions | Prefer the most conservative interpretation, e.g. a split flag in an archive without MHD_VOLUME means the entry is incomplete. |
| RAR 5.0 | Bound vints to 10 bytes and Header size to 3 vint bytes (2 MiB); check extra-record sizes against the extra area; check that Extra area size ≤ Header size. |

---

## 9. Errata

### 9.1 RARLAB documents

| # | Document | Statement | Correction | Evidence |
|---|----------|-----------|------------|----------|
| E1 | technote 3.93 | Declares block types `0x72`–`0x7A` only | RAR 3.x writes ENDARC_HEAD (`0x7B`) at the end of every archive | Observed in WinRAR 3.x archives (§7.9) |
| E2 | technote 1.53 | MAIN_HEAD flag `0x10` "unused" | Reassigned in RAR 3.x to new-style volume naming (technote 3.93) | Later technote |
| E3 | technote 3.93 | FILE_HEAD CRC covers "fields from HEAD_TYPE to FILEATTR and file name" | The CRC also covers SALT, EXT_TIME and any other bytes up to HEAD_SIZE | Verified on WinRAR 3.x archives with EXT_TIME (§11.2) |
| E4 | technote 3.93 | LHD_LARGE used for files "larger than 2Gb" | The low words are unsigned 32-bit; readers must honour the flag whenever it is set and not infer it from size | Field definitions |
| E5 | technote 3.93 | MAIN_HEAD described as fixed 13 bytes | HEAD_SIZE governs; later versions add bytes after offset 13 | §3.5.1 |
| E6 | RAR 5.0 format description | General header table gives the type of "Data area" as vint | The data area is raw bytes whose length is "Data size" | The same document's text |

### 9.2 Earlier revisions of this document

| # | Earlier statement | Correction |
|---|-------------------|------------|
| R1 | EXT_TIME is 2–19 bytes | 2–26 bytes (§3.11) |
| R2 | RAR5 compression information: dictionary in bits 10–13 | Bits 10–14 (`0x7C00`), plus version-1 fraction bits (§4.6.1) |
| R3 | RAR5 solid mode via header flag `0x0004` | Header flag `0x0004` is "skip if unknown"; solid is archive flag `0x0004` and compression-information bit `0x0040` |
| R4 | RAR5 file record listed mtime and CRC32 as always present | Both are optional (file flags `0x0002`, `0x0004`) |
| R5 | RAR 2.9 described as "four-tree dynamic Huffman" | The codes are static within a block and transmitted per block (§6.3.5) |
| R6 | RAR5 end/main/file records documented partially | Completed (§4) |
| R7 | Implementation notes and source descriptions relied on third-party decoder source code | Rewritten from public documentation and black-box observation (§11) |

---

## 10. Implementation status (SwiftRAR)

| Feature | Section | Status | Notes |
|---------|---------|--------|-------|
| Classic signature, SFX stub ≤ 1 MiB | §3.1 | Supported | |
| RAR 5.0 signature | §4.1 | Detected only | `RARError.unsupportedFeature(.rar5Archive)` |
| RAR 1.3/1.4 (`RE~^`) | §1.2 | Unsupported | Reported as not RAR |
| Block walk, skipping 0x75–0x79, NEWSUB and unknown types | §3.3 | Supported | Missing ENDARC tolerated; nothing after ENDARC read |
| HEAD_CRC verification | §6.2 | Supported | MAIN, FILE, NEWSUB, ENDARC; embedded-comment spans; legacy and unknown blocks not checked |
| MAIN_HEAD flags | §3.5 | Partial | MHD_VOLUME → `.multiVolume`, MHD_PASSWORD → `.encryptedHeaders`; others informational |
| FILE_HEAD fields, LHD_LARGE, SALT skip | §3.6 | Supported | |
| Split entries | §7.6 | Unsupported | `.multiVolume` |
| Names: 8-bit, UTF-8, compact UTF-16 | §3.13 | Supported | 8-bit names decoded as UTF-8 when valid, else CP437; `\` → `/` for hosts 0–2 |
| DOS time | §3.12 | Supported | Interpreted as UTC; invalid → `nil` |
| EXT_TIME | §3.11 | Partial | mtime refinement applied; ctime/atime/arctime parsed and skipped |
| Directory entries | §7.1 | Partial | Dictionary field 7; RAR 1.5 attribute-only directories not detected |
| Store | §5.2 | Supported | |
| RAR 2.9 LZ, non-solid | §6.3 | Supported | Validated byte-for-byte against bsdtar on real WinRAR 3.x archives (§11.2). The low-distance repeat symbol (16) and its reset on table reads do not occur in that corpus and are covered by spec-derived unit tests only |
| Solid continuation entries | §6.3.11 | Unsupported | `.solidEntry`; the first entry of a solid group extracts |
| Filter records | §6.3.9 | Unsupported | `.vmFilter` |
| PPMd blocks | §6.3.10 | Unsupported | `.ppmd` |
| RAR 1.5 / 2.0 algorithms | §6.4 | Unsupported | `.compressionVersion(v)` |
| Encryption | §6.5 | Unsupported | `.encryptedHeaders`, `.encryptedEntry` (entries still listed) |
| FILE_CRC verification | §6.1 | Supported | `.dataCRCMismatch` |
| Comments, recovery records, AV, NEWSUB services | §3.7–§3.9 | Unsupported | Skipped |
| RAR 5.0 container and compression | §4 | Unsupported | |
| Writing archives | — | Out of scope | |

---

## 11. References and provenance

### 11.1 References

| Reference | Author / publisher | Used for |
|-----------|--------------------|----------|
| "RAR version 1.53 – Technical information" (`technote.txt`) | Eugene Roshal | Block layout, MAIN/FILE/COMMENT headers, CRC note |
| "RAR version 3.93 – Technical information" (`technote.txt`, shipped with RAR/WinRAR) | Eugene Roshal / RARLAB | Block types, MAIN/FILE flags, LHD_UNICODE, SALT, EXT_TIME presence |
| "RAR 5.0 archive format" (rarlab.com/technote.htm) | RARLAB | §4 |
| "RAR (file format)", Wikipedia | Wikipedia contributors | History and version overview |
| RFC 1951, "DEFLATE Compressed Data Format Specification" | L. Peter Deutsch | Canonical prefix-code construction (§6.3.4) |
| "Catalogue of parametrised CRC algorithms" | Greg Cook | CRC-32/ISO-HDLC parameters and check value |
| RFC 7693, "The BLAKE2 Cryptographic Hash and MAC" | M-J. Saarinen, J-P. Aumasson | BLAKE2sp background |
| D. Shkarin, "PPM: one step to practicality" (DCC 2002) | Dmitry Shkarin | PPMd background |
| IANA media type registration `application/vnd.rar` | IANA | §1.3 |

### 11.2 Provenance

This document was written from the public documents listed in §11.1 and
from black-box observation: real archives written by WinRAR 3.x were
extracted with an independent tool (bsdtar 3.5.3 / libarchive 3.7.4, used
only as an executable) and the results were compared byte for byte, and CRC
for CRC, with an implementation written from this document. The validation
corpus was two archives with 242 entries: 238 RAR 2.9 LZ files, two stored
files and two directories, three of the headers carrying EXT_TIME; every file
matched and every name and directory agreed with the reference listing. Facts about the RAR 2.9
bitstream that RARLAB does not publish (§6.3) are stated as the author
understands the format and are confirmed by that comparison. No third-party
source code (unrar, 7-Zip, libarchive, The Unarchiver or any other RAR
implementation) was consulted, quoted or paraphrased while writing this
document or SwiftRAR's implementation.

RAR and WinRAR are trademarks of their owner. The RAR format was designed by
Eugene Roshal and is maintained by RARLAB (win.rar GmbH). SwiftRAR only
reads archives; it does not create them.
