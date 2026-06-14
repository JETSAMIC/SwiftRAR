import XCTest
@testable import SwiftRAR

final class CRC32Tests: XCTestCase {

    func testEmptyData() {
        XCTAssertEqual(CRC32.compute(Data()), 0x00000000)
    }

    func testKnownVectorForASCII123456789() {
        // Standard CRC32 test vector: "123456789" => 0xCBF43926.
        let data = Data("123456789".utf8)
        XCTAssertEqual(CRC32.compute(data), 0xCBF43926)
    }

    func testKnownVectorForSingleByteA() {
        // "a" => 0xE8B7BE43
        let data = Data("a".utf8)
        XCTAssertEqual(CRC32.compute(data), 0xE8B7BE43)
    }

    func testKnownVectorForAlphabet() {
        // "The quick brown fox jumps over the lazy dog" => 0x414FA339
        let data = Data("The quick brown fox jumps over the lazy dog".utf8)
        XCTAssertEqual(CRC32.compute(data), 0x414FA339)
    }

    func testVerifyMatchesAndMismatches() {
        let data = Data("hello".utf8)
        let crc = CRC32.compute(data)
        XCTAssertTrue(CRC32.verify(data, expected: crc))
        XCTAssertFalse(CRC32.verify(data, expected: crc &+ 1))
    }

    func testSequenceOverloadMatchesDataOverload() {
        let bytes: [UInt8] = Array("RAR archive".utf8)
        XCTAssertEqual(CRC32.compute(bytes), CRC32.compute(Data(bytes)))
    }
}
