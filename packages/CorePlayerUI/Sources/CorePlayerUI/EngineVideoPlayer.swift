//
//  PlayerUI.swift
//  CorePlayerUI
//
//  Native SwiftUI playback chrome backed by CorePlayerEngine.
//

import SwiftUI
import AVKit
import Combine
import CorePlayerEngine

/// Formats playback positions consistently across the player controls.
public enum PlayerTimeFormatter {
    public static func string(from time: TimeInterval) -> String {
        let boundedTime = time.isFinite ? min(max(time, 0), 359_999_999) : 0
        let safeTime = Int(boundedTime)
        let hours = safeTime / 3_600
        let minutes = (safeTime % 3_600) / 60
        let seconds = safeTime % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Observable presentation state that adapts the engine's async streams for SwiftUI.
@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public private(set) var presentationPlayer: AVPlayer?
    @Published public private(set) var state: PlayerState = .idle
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval?
    @Published public private(set) var bufferedTime: TimeInterval?
    @Published public private(set) var lastError: PlayerError?
    @Published public private(set) var areControlsVisible = true
    @Published public private(set) var isSeeking = false
    @Published public private(set) var seekPosition: TimeInterval = 0

    private let engine: any PlayerEngine
    private var stateTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?

    public init(engine: any PlayerEngine) {
        self.engine = engine
    }

    public var displayedTime: TimeInterval {
        isSeeking ? seekPosition : currentTime
    }

    public var canSeek: Bool {
        state.isSeekable && (duration ?? 0) > 0
    }

    public func startObserving() {
        guard stateTask == nil, eventsTask == nil else { return }
        refreshPresentationPlayer()

        stateTask = Task { [weak self, engine] in
            for await nextState in engine.state {
                guard let self else { return }
                self.state = nextState
                self.refreshPresentationPlayer()
                if case let .error(error) = nextState {
                    self.lastError = error
                } else {
                    self.lastError = nil
                }
            }
        }

        eventsTask = Task { [weak self, engine] in
            for await event in engine.events {
                guard let self else { return }
                if case let .progress(progress) = event {
                    self.currentTime = max(0, progress.currentTime)
                    self.duration = progress.duration
                    self.bufferedTime = progress.buffered
                    if !self.isSeeking {
                        self.seekPosition = self.currentTime
                    }
                }
            }
        }
    }

    public func stopObserving() {
        stateTask?.cancel()
        eventsTask?.cancel()
        stateTask = nil
        eventsTask = nil
        controlsTask?.cancel()
        controlsTask = nil
    }

    public func togglePlayback() async {
        do {
            switch state {
            case .playing, .buffering:
                try await engine.pause()
            case .ended:
                try await engine.seek(to: 0)
                try await engine.play()
            case .ready, .paused:
                try await engine.play()
            default:
                break
            }
        } catch {
            apply(error: error)
        }
    }

    public func beginSeeking() {
        guard canSeek else { return }
        isSeeking = true
        seekPosition = currentTime
    }

    public func updateSeekPosition(_ position: TimeInterval) {
        guard canSeek else { return }
        let upperBound = max(0, duration ?? 0)
        seekPosition = min(max(0, position), upperBound)
    }

    public func commitSeek() async {
        guard canSeek, isSeeking else { return }
        let target = seekPosition
        isSeeking = false
        do {
            try await engine.seek(to: target)
            currentTime = target
        } catch {
            apply(error: error)
        }
    }

    public func revealControls() {
        areControlsVisible = true
        controlsTask?.cancel()
        controlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.areControlsVisible = false
        }
    }

    public func toggleControlsVisibility() {
        if areControlsVisible {
            controlsTask?.cancel()
            areControlsVisible = false
        } else {
            revealControls()
        }
    }

    private func refreshPresentationPlayer() {
        guard presentationPlayer == nil,
              let provider = engine as? any AVPlayerProviding
        else { return }
        presentationPlayer = provider.presentationPlayer
    }

    private func apply(error: Error) {
        let playerError = PlayerError.from(error)
        lastError = playerError
        state = .error(playerError)
    }
}

/// A complete, reusable player surface. Playback, seeking and progress are driven by
/// the supplied engine; this view does not create or own the underlying player.
public struct EngineVideoPlayer: View {
    @StateObject private var model: PlayerViewModel
    private let title: String?

    public init(engine: any PlayerEngine, title: String? = nil) {
        _model = StateObject(wrappedValue: PlayerViewModel(engine: engine))
        self.title = title
    }

    public var body: some View {
        ZStack {
            if let player = model.presentationPlayer {
                VideoPlayer(player: player)
                    .allowsHitTesting(false)
            } else {
                Color.black
            }

            centerContent

            if model.areControlsVisible {
                VStack(spacing: 0) {
                    topControls
                    Spacer(minLength: 0)
                    bottomControls
                }
                .background {
                    LinearGradient(
                        colors: [.black.opacity(0.58), .clear, .clear, .black.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggleControlsVisibility()
        }
        .animation(.easeInOut(duration: 0.2), value: model.areControlsVisible)
        .onAppear {
            model.startObserving()
            model.revealControls()
        }
        .onDisappear {
            model.stopObserving()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "Video player")
    }

    @ViewBuilder
    private var centerContent: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading")
                .tint(.white)
                .foregroundStyle(.white)
        case .buffering:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
                .accessibilityLabel("Buffering")
        case .reconnecting:
            PlaybackStatusOverlay(
                symbol: "wifi.exclamationmark",
                title: "Reconnecting",
                message: "Trying to restore the stream"
            )
        case let .error(error):
            PlaybackErrorOverlay(message: error.playerMessage)
        case .ended:
            Button {
                Task { await model.togglePlayback() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(22)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replay")
        default:
            EmptyView()
        }
    }

    private var topControls: some View {
        HStack {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 24)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            PlayerProgressBar(
                currentTime: model.displayedTime,
                duration: model.duration,
                bufferedTime: model.bufferedTime,
                isEnabled: model.canSeek,
                onEditingChanged: { editing in
                    if editing {
                        model.beginSeeking()
                    } else {
                        Task { await model.commitSeek() }
                    }
                },
                onValueChanged: model.updateSeekPosition
            )

            HStack(spacing: 14) {
                Button {
                    Task { await model.togglePlayback() }
                    model.revealControls()
                } label: {
                    Image(systemName: playbackSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canTogglePlayback)
                .accessibilityLabel(playbackAccessibilityLabel)

                Text(PlayerTimeFormatter.string(from: model.displayedTime))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Text("/")
                    .foregroundStyle(.white.opacity(0.65))

                Text(model.duration.map(PlayerTimeFormatter.string(from:)) ?? "--:--")
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    private var playbackSymbol: String {
        switch model.state {
        case .playing, .buffering:
            return "pause.fill"
        default:
            return "play.fill"
        }
    }

    private var playbackAccessibilityLabel: String {
        switch model.state {
        case .playing, .buffering:
            return "Pause"
        case .ended:
            return "Replay"
        default:
            return "Play"
        }
    }

    private var canTogglePlayback: Bool {
        switch model.state {
        case .ready, .playing, .paused, .buffering, .ended:
            return true
        default:
            return false
        }
    }
}

private struct PlayerProgressBar: View {
    @State private var isEditing = false

    let currentTime: TimeInterval
    let duration: TimeInterval?
    let bufferedTime: TimeInterval?
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void
    let onValueChanged: (TimeInterval) -> Void

    private var safeDuration: TimeInterval {
        max(0, duration ?? 0)
    }

    private func fraction(for time: TimeInterval) -> CGFloat {
        guard safeDuration > 0 else { return 0 }
        return CGFloat(min(max(time / safeDuration, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let played = width * fraction(for: currentTime)
            let buffered = width * fraction(for: bufferedTime ?? 0)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white.opacity(0.48))
                    .frame(width: buffered)
                Capsule()
                    .fill(.white)
                    .frame(width: played)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .offset(x: min(max(played - 6, 0), width - 12))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onValueChanged(safeDuration * fraction)
                    }
                    .onEnded { value in
                        guard isEnabled else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onValueChanged(safeDuration * fraction)
                        if isEditing {
                            isEditing = false
                            onEditingChanged(false)
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(PlayerTimeFormatter.string(from: currentTime)) of \(duration.map(PlayerTimeFormatter.string(from:)) ?? "unknown duration")"
            )
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                let step: TimeInterval = direction == .increment ? 5 : -5
                onEditingChanged(true)
                onValueChanged(min(max(currentTime + step, 0), safeDuration))
                onEditingChanged(false)
            }
        }
        .frame(height: 28)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct PlaybackStatusOverlay: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct PlaybackErrorOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
            Text("Playback unavailable")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: 300)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private extension PlayerError {
    var playerMessage: String {
        switch self {
        case .invalidSource:
            return "The media source is invalid."
        case .unsupportedFormat:
            return "This media format is not supported."
        case .network(.offline):
            return "You appear to be offline. Check your connection and try again."
        case .network(.timeout):
            return "The connection timed out."
        case .network(.serverError(let statusCode)):
            return "The streaming server returned an error (\(statusCode))."
        case .network(.unreachable):
            return "The streaming server could not be reached."
        case .network(.retryExhausted):
            return "The stream could not be recovered after several attempts."
        case .network(.unknown):
            return "A network error interrupted playback."
        case .decodingFailed:
            return "The media could not be decoded."
        case .playbackStalled:
            return "Playback stalled and could not recover."
        case .seekFailed:
            return "The requested position could not be reached."
        case .system:
            return "A system error interrupted playback."
        case .unknown:
            return "An unexpected error interrupted playback."
        }
    }
}
