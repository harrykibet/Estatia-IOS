import Testing
import CorePlayerEngine
@testable import CorePlayerUI

@Test func playerEngineIsAvailableToPlayerUIPackage() {
    #expect(PlayerState.idle == .idle)
}
