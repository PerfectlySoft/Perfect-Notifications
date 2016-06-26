import XCTest
@testable import PerfectNotifications

class PerfectNotificationsTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        XCTAssertEqual(PerfectNotifications().text, "Hello, World!")
    }


    static var allTests : [(String, (PerfectNotificationsTests) -> () throws -> Void)] {
        return [
            ("testExample", testExample),
        ]
    }
}
