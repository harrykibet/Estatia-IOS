import Testing
import CorePlayerEngine
@testable import CorePlayerUI

@Test func playerEngineIsAvailableToPlayerUIPackage() {
    #expect(PlayerState.idle == .idle)
}

@Test func playerTimeFormatterUsesMinuteAndSecondFormat() {
    #expect(PlayerTimeFormatter.string(from: 0) == "0:00")
    #expect(PlayerTimeFormatter.string(from: 65) == "1:05")
    #expect(PlayerTimeFormatter.string(from: 3_599) == "59:59")
}

@Test func playerTimeFormatterIncludesHoursWhenNeeded() {
    #expect(PlayerTimeFormatter.string(from: 3_600) == "1:00:00")
    #expect(PlayerTimeFormatter.string(from: 3_661) == "1:01:01")
}

@Test func playerTimeFormatterClampsNegativeAndNonFiniteValues() {
    #expect(PlayerTimeFormatter.string(from: -12) == "0:00")
    #expect(PlayerTimeFormatter.string(from: .infinity) == "0:00")
    #expect(PlayerTimeFormatter.string(from: .nan) == "0:00")
}

@Test func pressAndHoldPausesAndResumesOnlyPlaybackThatWasAlreadyActive() {
    var interaction = PlayerHoldInteraction()

    #expect(interaction.handle(.began, isPlaying: true) == .pause)
    #expect(interaction.handle(.ended, isPlaying: false) == .resume)
}

@Test func pressAndHoldDoesNotStartPreviouslyPausedPlayback() {
    var interaction = PlayerHoldInteraction()

    #expect(interaction.handle(.began, isPlaying: false) == .none)
    #expect(interaction.handle(.ended, isPlaying: false) == .none)
}

@Test func cancelledPressDoesNotResumePlayback() {
    var interaction = PlayerHoldInteraction()

    #expect(interaction.handle(.began, isPlaying: true) == .pause)
    #expect(interaction.handle(.cancelled, isPlaying: false) == .none)
    #expect(interaction.handle(.ended, isPlaying: false) == .none)
}
