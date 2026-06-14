import XCTest
@testable import SwiftRAR

final class SignatureTests: XCTestCase {

    func testDetectClassicSignatureAtOffsetZero() {
        let data = Data(RARSignature.classicBytes)
        let detection = RARSignature.detect(data)
        XCTAssertEqual(detection?.format, .classic)
        XCTAssertEqual(detection?.signatureOffset, 0)
        XCTAssertEqual(detection?.bodyOffset, 7)
    }

    func testDetectRAR5SignatureAtOffsetZero() {
        let data = Data(RARSignature.rar5Bytes)
        let detection = RARSignature.detect(data)
        XCTAssertEqual(detection?.format, .rar5)
        XCTAssertEqual(detection?.signatureOffset, 0)
        XCTAssertEqual(detection?.bodyOffset, 8)
    }

    func testDetectSFXPrefixedClassicArchive() {
        var data = Data(repeating: 0xAB, count: 4096)  // pretend SFX stub
        data.append(contentsOf: RARSignature.classicBytes)
        let detection = RARSignature.detect(data)
        XCTAssertEqual(detection?.format, .classic)
        XCTAssertEqual(detection?.signatureOffset, 4096)
        XCTAssertEqual(detection?.bodyOffset, 4096 + 7)
    }

    func testDetectSFXPrefixedRAR5Archive() {
        var data = Data(repeating: 0xCD, count: 2048)
        data.append(contentsOf: RARSignature.rar5Bytes)
        let detection = RARSignature.detect(data)
        XCTAssertEqual(detection?.format, .rar5)
        XCTAssertEqual(detection?.signatureOffset, 2048)
    }

    func testRejectsNonRARData() {
        let data = Data("This is just plain text, not a RAR archive at all.".utf8)
        XCTAssertNil(RARSignature.detect(data))
    }

    func testRejectsTooShortData() {
        let data = Data([0x52, 0x61, 0x72])  // "Rar"
        XCTAssertNil(RARSignature.detect(data))
    }

    func testRejectsCorruptVersionByte() {
        // First 6 bytes match the prefix but version byte is 0x02 (not a
        // known version).
        let data = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x02, 0x00])
        XCTAssertNil(RARSignature.detect(data))
    }

    func testRAR5SignatureMissingTrailingZeroIsRejected() {
        // 7 bytes matching the classic prefix + 0x01 but no 0x00 trailer.
        // Detector should keep scanning; with only this much data it
        // produces nil.
        let data = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01])
        XCTAssertNil(RARSignature.detect(data))
    }

    func testIsRARArchiveConvenience() {
        XCTAssertTrue(RARArchive.isRARArchive(Data(RARSignature.classicBytes)))
        XCTAssertFalse(RARArchive.isRARArchive(Data("not a rar".utf8)))
    }
}
