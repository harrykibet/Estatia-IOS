import Foundation
import XCTest
import AVFoundation
@testable import CorePlayerEngine

final class PlayerErrorMappingTests: XCTestCase {
    func testDecoderNotFoundMapsToDecoderUnavailable() {
        let error = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.decoderNotFound.rawValue
        )

        XCTAssertEqual(PlayerError.from(error), .decoderUnavailable)
    }

    func testDecoderTemporarilyUnavailableMapsToDecoderUnavailable() {
        let error = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.decoderTemporarilyUnavailable.rawValue
        )

        XCTAssertEqual(PlayerError.from(error), .decoderUnavailable)
    }

    func testGenericDecodeFailureDoesNotBecomeDecoderInitializationFailure() {
        let error = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.decodeFailed.rawValue
        )

        XCTAssertEqual(PlayerError.from(error), .decodingFailed)
    }

    func testNestedDecoderErrorIsPreserved() {
        let underlying = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.decoderNotFound.rawValue
        )
        let wrapped = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertEqual(PlayerError.from(wrapped), .decoderUnavailable)
    }

    func testNetworkErrorWrappedByAVFoundationRemainsNetworkError() {
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut
        )
        let wrapped = NSError(
            domain: AVError.errorDomain,
            code: AVError.Code.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertEqual(PlayerError.from(wrapped), .network(.timeout))
    }
}
