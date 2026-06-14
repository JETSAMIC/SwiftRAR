import XCTest
@testable import SwiftRAR

final class SwiftRARTests: XCTestCase {
    func testPackageVersionIsSet() {
        XCTAssertFalse(SwiftRAR.version.isEmpty)
    }
}
