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

@Test @MainActor func playerViewModelShowsLowBandwidthOnlyDuringActivePlayback() async {
    let engine = LowBandwidthTestPlayerEngine()
    let model = PlayerViewModel(engine: engine)
    model.startObserving()

    engine.emit(state: .playing)
    engine.emit(event: .lowBandwidthChanged(isSustained: true))
    for _ in 0..<20 { await Task.yield() }

    #expect(model.isLowBandwidth)
    #expect(model.shouldShowLowBandwidthWarning)

    engine.emit(state: .paused)
    for _ in 0..<20 { await Task.yield() }

    #expect(model.isLowBandwidth)
    #expect(!model.shouldShowLowBandwidthWarning)

    engine.emit(event: .lowBandwidthChanged(isSustained: false))
    for _ in 0..<20 { await Task.yield() }

    #expect(!model.isLowBandwidth)
    #expect(!model.shouldShowLowBandwidthWarning)
    model.stopObserving()
}

@MainActor
private final class LowBandwidthTestPlayerEngine: PlayerEngine {
    private let stateEmitter = PlayerEventEmitter<PlayerState>()
    private let eventEmitter = PlayerEventEmitter<PlayerEvent>()
    var isSustainedLowBandwidth = false

    var state: AsyncStream<PlayerState> { stateEmitter.stream }
    var events: AsyncStream<PlayerEvent> { eventEmitter.stream }

    var currentState: PlayerState {
        get async { .idle }
    }

    var currentTime: TimeInterval {
        get async { 0 }
    }

    var duration: TimeInterval? {
        get async { 60 }
    }

    func load(_ source: MediaSource) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func seek(to seconds: TimeInterval) async throws {}
    func stop() async throws {}
    func release() async throws {}
    func notifyNetworkLost() async {}
    func notifyRecoveryExhausted() async {}

    func emit(state: PlayerState) {
        stateEmitter.emit(state)
    }

    func emit(event: PlayerEvent) {
        eventEmitter.emit(event)
    }
}

