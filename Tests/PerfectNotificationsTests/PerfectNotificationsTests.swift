import XCTest
import PerfectLib
@testable import PerfectNotifications

class PerfectNotificationsTests: XCTestCase {
    func testBase64() {
		let data: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
		let buffer = UnsafeRawBufferPointer(start: UnsafePointer(data), count: data.count)
		guard let r = buffer.base64 else {
			return XCTAssert(false, "nil ptr")
		}
		XCTAssert(r == "AAECAwQFBgcICQo=", "\(r)")
    }

	func testMakeSignature() {
		let apnsKeyIdentifier = "5C9QCHB5XE"
		let apnsTeamIdentifier = "L2NAZNC754"
		let apnsPrivateKey = "/Users/kjessup/development/PerfectNeu/Perfect-NotificationsExample/APNSAuthKey_5C9QCHB5XE.p8"
		
		let sig = makeSignature(keyId: apnsKeyIdentifier, teamId: apnsTeamIdentifier, privateKeyPath: apnsPrivateKey)
		print(sig)
		XCTAssert(nil != sig)
	}
	
    static var allTests : [(String, (PerfectNotificationsTests) -> () throws -> Void)] {
        return [
            ("testBase64", testBase64),
        ]
    }
}
