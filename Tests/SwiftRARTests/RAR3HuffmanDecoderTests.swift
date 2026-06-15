import XCTest
@testable import SwiftRAR

final class RAR3HuffmanDecoderTests: XCTestCase {

    /// Canonical-Huffman build from RFC 1951 §3.2.2 example.
    ///
    /// Symbols A..H with code lengths [3, 3, 3, 3, 3, 2, 4, 4] yield:
    ///   F = 00      (length 2)
    ///   A = 010     B = 011    C = 100    D = 101    E = 110  (length 3)
    ///   G = 1110    H = 1111   (length 4)
    ///
    /// Verify that encoding each bit pattern in turn produces the
    /// matching symbol index.
    func testCanonicalRFC1951Example() throws {
        // Symbols 0..7 map to A..H.
        let lengths: [UInt8] = [3, 3, 3, 3, 3, 2, 4, 4]
        let decoder = try RAR3HuffmanDecoder(codeLengths: lengths)

        // Each entry: (encoded bit pattern as a byte sequence, expected
        // symbol). The decoder reads MSB-first, so we left-justify each
        // code in the first byte.
        // For consistent reading we'll build a stream where codes are
        // concatenated tightly and decode them in order.
        // Sequence: F A B C D E G H = 00 010 011 100 101 110 1110 1111
        //         = 00010 01110 01011 10111 01111
        //         = 0001 0011 1001 0111 0111 1111
        //         = 0x13 0x97 0x7F
        // Build by hand:
        //   00 010 011 100 101 110 1110 1111
        //   = 26 bits total
        // Concatenated MSB-first:
        //   bits: 0 0 0 1 0 0 1 1 1 0 0 1 0 1 1 1 0 1 1 1 0 1 1 1 1
        // Wait, recount: F(00) A(010) B(011) C(100) D(101) E(110) G(1110) H(1111)
        // = 2 + 3 + 3 + 3 + 3 + 3 + 4 + 4 = 25 bits.
        // Concatenated: 00 010 011 100 101 110 1110 1111
        //             = 0001001110010111011101111
        // Group into bytes (MSB-first, pad with zero):
        //   00010011 10010111 01110111 1_______
        //   = 0x13, 0x97, 0x77, 0x80 (last byte: 1000 0000)
        let payload = Data([0x13, 0x97, 0x77, 0x80])
        var stream = BitStream(payload)
        let expectedSymbols: [UInt16] = [5, 0, 1, 2, 3, 4, 6, 7] // F A B C D E G H
        for want in expectedSymbols {
            let got = try decoder.decode(&stream)
            XCTAssertEqual(got, want)
        }
    }

    /// A trivial two-symbol table assigns codes 0 and 1.
    func testTwoSymbolTable() throws {
        // Symbols 0 and 1 both have length 1 → codes 0 and 1.
        let decoder = try RAR3HuffmanDecoder(codeLengths: [1, 1])
        XCTAssertEqual(decoder.symbolCount, 2)

        // Bits: 0 1 1 0 0 1 = byte 0b01100100 = 0x64
        var stream = BitStream(Data([0x64]))
        let expected: [UInt16] = [0, 1, 1, 0, 0, 1, 0, 0]
        for want in expected {
            XCTAssertEqual(try decoder.decode(&stream), want)
        }
    }

    /// A length-zero entry means the symbol is absent — never decoded.
    func testZeroLengthSymbolIsAbsent() throws {
        // Symbols 0 and 2 are present (length 1 each); symbol 1 is absent.
        let decoder = try RAR3HuffmanDecoder(codeLengths: [1, 0, 1])
        XCTAssertEqual(decoder.symbolCount, 2)
        var stream = BitStream(Data([0b01000000]))
        XCTAssertEqual(try decoder.decode(&stream), 0) // bit 0
        XCTAssertEqual(try decoder.decode(&stream), 2) // bit 1
    }

    /// An over-subscribed table is rejected.
    func testOverSubscribedTableThrows() {
        // Three symbols of length 1 is impossible (only 0 and 1 fit).
        XCTAssertThrowsError(try RAR3HuffmanDecoder(codeLengths: [1, 1, 1]))
    }

    /// An empty table builds without throwing; decoding throws.
    func testEmptyTableIsEmpty() throws {
        let decoder = try RAR3HuffmanDecoder(codeLengths: [0, 0, 0, 0])
        XCTAssertTrue(decoder.isEmpty)
        var stream = BitStream(Data([0xFF]))
        XCTAssertThrowsError(try decoder.decode(&stream))
    }

    /// Code length above the cap is rejected.
    func testLengthAboveCapThrows() {
        XCTAssertThrowsError(try RAR3HuffmanDecoder(codeLengths: [16]))
    }
}
