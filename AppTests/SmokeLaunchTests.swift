import XCTest

final class SmokeLaunchTests: XCTestCase {
    func testHostAppBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.aarzamen.ichirp")
    }
}
