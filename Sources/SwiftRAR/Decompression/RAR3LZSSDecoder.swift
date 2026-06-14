import Foundation

/// Placeholder for the RAR3 LZSS + Huffman + PPMd decompressor (compression
/// methods `0x31` through `0x35`).
///
/// ### Why this is a stub
///
/// Implementing the RAR3 compressed methods from scratch is a multi-week
/// effort and a non-trivial legal exercise:
///
/// 1. **RAR3 normal/best methods** combine a custom LZSS variant with
///    variable-length Huffman codes for literals, lengths and distances,
///    plus optional multimedia filters (audio, RGB, x86/ARM bytecode,
///    advanced text). The format is documented in the public
///    `technote.txt` shipped with WinRAR ≤4.x, in the Kaitai Struct RAR
///    spec, and in clean-room reimplementations such as `rarfile`
///    (Python, ISC) and the bitjs `unrar.js` (Apache-2.0). Implementing
///    the bitstream + filter stack from spec is roughly 1-2 weeks of
///    careful Swift, plus 1-2 weeks of validation against real-world
///    archives.
///
/// 2. **RAR3 "best" method** can switch into PPMII (Dmitry Shkarin's
///    PPMd) mid-stream for text-heavy data. PPMd is public domain
///    (Shkarin's license explicitly permits re-use with attribution and
///    forbids only patenting and authorship misattribution) and can be
///    ported from canonical PPMd J1 sources — but the port itself is
///    another ~2000 lines of careful state-machine code.
///
/// 3. **Licensing constraint**: The reference UnRAR source from rarlab
///    carries a non-OSI license that prohibits using it to "develop a
///    RAR (WinRAR) compatible archiver" and is incompatible with MIT.
///    SwiftRAR is decompression-only, so the spirit of the UnRAR
///    license would arguably permit reference — but for an MIT-licensed
///    Swift package intended to be vendored into other projects, the
///    safer posture is to implement strictly from spec without reading
///    UnRAR's source. That cost is folded into the time estimate above.
///
/// 4. **RAR5 decompression** adds another 1-2 weeks on top: a redesigned
///    bitstream, a 1 GB+ dictionary, and a new filter set (delta, x86,
///    ARM64, RGB, audio). Algorithm versions 0 and 1 are both deployed
///    in archives produced by WinRAR 5.x / 6.x / 7.x.
///
/// ### What ships today
///
/// Until the full decompressor is in place, `decompress` simply throws
/// `RARError.unsupportedCompression(method:)` with the offending method
/// byte. Callers can branch on this error to either:
///
/// - Refuse the archive at download time (e.g. Relical's 16colors
///   importer rejects archives whose entries are not all STORE).
/// - Surface the metadata SwiftRAR can still produce (filenames, sizes,
///   CRCs) alongside a "please extract with The Unarchiver" message.
/// - Defer to a license-encumbered native binding (libunrar, libarchive
///   RAR3 reader) shipped as a separate optional target.
///
/// - TODO: Implement RAR3 LZSS + Huffman (~1 week clean-room from spec).
/// - TODO: Implement RAR3 multimedia / text filters (~3 days).
/// - TODO: Port PPMd from Shkarin's public-domain reference with
///   attribution (~1 week).
/// - TODO: Implement RAR5 algorithm versions 0 and 1 (~2 weeks).
enum RAR3LZSSDecoder {
    static func decompress(_ entry: RAREntry, from archive: Data) throws -> Data {
        throw RARError.unsupportedCompression(method: entry.compressionMethod)
    }
}
