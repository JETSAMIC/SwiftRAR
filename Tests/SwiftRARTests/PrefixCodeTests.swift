import XCTest
@testable import SwiftRAR

/// Reference §6.3.4: canonical prefix codes built from code lengths.
final class PrefixCodeTests: XCTestCase {

    private func decodeAll(_ code: PrefixCode, _ bytes: [UInt8], count: Int) throws -> [Int] {
        var reader = MSBBitReader(bytes)
        return try (0..<count).map { _ in try code.decode(&reader) }
    }

    /// RFC 1951 §3.2.2 example: lengths (3,3,3,3,3,2,4,4) give
    /// F=00, A=010, B=011, C=100, D=101, E=110, G=1110, H=1111.
    func testCanonicalAssignmentMatchesRFC1951Example() throws {
        let code = try PrefixCode(lengths: [3, 3, 3, 3, 3, 2, 4, 4] as [UInt8])
        // F A B C D E G H = 00 010 011 100 101 110 1110 1111
        let bits = "00" + "010" + "011" + "100" + "101" + "110" + "1110" + "1111"
        XCTAssertEqual(try decodeAll(code, pack(bits), count: 8), [5, 0, 1, 2, 3, 4, 6, 7])
    }

    func testCodesLongerThanTheLookupTable() throws {
        // Symbol k (k < 14) has length k + 1; symbols 14 and 15 have length 15.
        var lengths: [UInt8] = (0..<14).map { UInt8($0 + 1) }
        lengths += [15, 15]
        let code = try PrefixCode(lengths: lengths)
        // Canonical codes: 0, 10, 110, …, 1…10 (14 ones then 0), 111111111111111.
        let thirteen = String(repeating: "1", count: 13) + "0"
        let fourteen = String(repeating: "1", count: 14) + "0"
        let last = String(repeating: "1", count: 15)
        XCTAssertEqual(try decodeAll(code, pack(thirteen + fourteen + last + "0"), count: 4), [13, 14, 15, 0])
    }

    func testSingleSymbolCodeIsIncompleteButUsable() throws {
        var lengths = [UInt8](repeating: 0, count: 10)
        lengths[7] = 1
        let code = try PrefixCode(lengths: lengths)
        XCTAssertEqual(try decodeAll(code, [0b0000_0000], count: 3), [7, 7, 7])
        XCTAssertThrowsError(try decodeAll(code, [0b1000_0000], count: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testEmptyCodeRejectsEveryInput() throws {
        let code = try PrefixCode(lengths: [UInt8](repeating: 0, count: 20))
        XCTAssertThrowsError(try decodeAll(code, [0x00, 0x00], count: 1)) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testOversubscribedLengthsAreCorrupt() {
        XCTAssertThrowsError(try PrefixCode(lengths: [1, 1, 1] as [UInt8])) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
        XCTAssertThrowsError(try PrefixCode(lengths: [16] as [UInt8])) {
            XCTAssertEqual($0 as? RARError, .corruptData)
        }
    }

    func testCodeRunningPastTheEndIsTruncation() throws {
        let code = try PrefixCode(lengths: [UInt8](repeating: 4, count: 16))
        // One full 4-bit code, then the stream ends after 4 more bits.
        XCTAssertThrowsError(try decodeAll(code, [0x12], count: 3)) {
            XCTAssertEqual($0 as? RARError, .truncated)
        }
    }

    private func pack(_ bits: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var current: UInt8 = 0
        var used = 0
        for bit in bits {
            current = current << 1 | (bit == "1" ? 1 : 0)
            used += 1
            if used == 8 { bytes.append(current); current = 0; used = 0 }
        }
        if used > 0 { bytes.append(current << (8 - used)) }
        return bytes
    }
}
