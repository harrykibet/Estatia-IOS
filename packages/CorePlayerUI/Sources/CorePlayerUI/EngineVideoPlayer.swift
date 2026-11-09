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
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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


/// Models the pause/resume contract for a press-and-hold gesture.
/// A cancelled gesture never resumes playback; only a normal release does.
enum PlayerHoldGestureEvent {
    case began
    case ended
    case cancelled
}

enum PlayerHoldPlaybackAction: Equatable {
    case none
    case pause
    case resume
}

struct PlayerHoldInteraction {
    private(set) var wasPlayingBeforeHold = false

    mutating func handle(
        _ event: PlayerHoldGestureEvent,
        isPlaying: Bool
    ) -> PlayerHoldPlaybackAction {
        switch event {
        case .began:
            wasPlayingBeforeHold = isPlaying
            return isPlaying ? .pause : .none
        case .ended:
            defer { wasPlayingBeforeHold = false }
            return wasPlayingBeforeHold ? .resume : .none
        case .cancelled:
            wasPlayingBeforeHold = false
            return .none
        }
    }
}

/// Observable presentation state that adapts the engine's async streams for SwiftUI.
@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public private(set) var presentationPlayer: AVPlayer?
    @Published public private(set) var state: PlayerState = .idle
    @Published public private(set) var isLowBandwidth = false
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
    private var holdPlaybackTask: Task<Void, Never>?
    private var holdInteraction = PlayerHoldInteraction()

    public init(engine: any PlayerEngine) {
        self.engine = engine
    }

    public var displayedTime: TimeInterval {
        isSeeking ? seekPosition : currentTime
    }

    public var hasPresentationPlayer: Bool { presentationPlayer != nil }

    public var canSeek: Bool {
        state.isSeekable && (duration ?? 0) > 0
    }

    /// The low-bandwidth notice is informational and appears only while the
    /// transport is actively playing or buffering.
    public var shouldShowLowBandwidthWarning: Bool {
        isLowBandwidth && (state == .playing || state == .buffering)
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

        // Subscribe before reading the snapshot: any change racing with this
        // read is also buffered in the stream and cannot be missed.
        let eventStream = engine.events
        isLowBandwidth = engine.isSustainedLowBandwidth

        eventsTask = Task { [weak self] in
            for await event in eventStream {
                guard let self else { return }
                switch event {
                case let .progress(progress):
                    self.currentTime = max(0, progress.currentTime)
                    self.duration = progress.duration
                    self.bufferedTime = progress.buffered
                    if !self.isSeeking {
                        self.seekPosition = self.currentTime
                    }
                case let .lowBandwidthChanged(isSustained):
                    self.isLowBandwidth = isSustained
                default:
                    break
                }
            }
        }
    }

    public func stopObserving() {
        cancelPress()
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

    /// Mutes the underlying AVPlayer when the host supplies a mute preference.
    public func setMuted(_ muted: Bool) {
        presentationPlayer?.isMuted = muted
    }

    /// Mirrors Android's press-and-hold behavior. The engine remains the
    /// authority for playback commands; release resumes only if playback was
    /// active when the hold began.
    public func pressChanged(_ isPressed: Bool) {
        let action = holdInteraction.handle(
            isPressed ? .began : .ended,
            isPlaying: state == .playing
        )
        performHoldAction(action)
    }

    /// A cancelled gesture or disappearing view must not restart playback.
    public func cancelPress() {
        let action = holdInteraction.handle(.cancelled, isPlaying: false)
        performHoldAction(action)
    }

    private func performHoldAction(_ action: PlayerHoldPlaybackAction) {
        switch action {
        case .none:
            break
        case .pause:
            holdPlaybackTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.engine.pause()
                } catch {
                    self.apply(error: error)
                }
            }
        case .resume:
            let pauseTask = holdPlaybackTask
            holdPlaybackTask = Task { [weak self] in
                await pauseTask?.value
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.engine.play()
                } catch {
                    self.apply(error: error)
                }
            }
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
    private let isMuted: Bool?
    private let onMuteToggle: (() -> Void)?
    private let onLike: (() -> Void)?

    /// - Parameters:
    ///   - engine: The player engine that owns playback and seeking.
    ///   - title: Optional accessible/display title for the video.
    ///   - isMuted: Host-owned mute preference. When supplied with onMuteToggle,
    ///     a mute button is shown and the preference is applied to AVPlayer.
    ///   - onMuteToggle: Callback for changing the host-owned mute preference.
    ///   - onLike: Called for a double tap on the video surface.
    public init(
        engine: any PlayerEngine,
        title: String? = nil,
        isMuted: Bool? = nil,
        onMuteToggle: (() -> Void)? = nil,
        onLike: (() -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: PlayerViewModel(engine: engine))
        self.title = title
        self.isMuted = isMuted
        self.onMuteToggle = onMuteToggle
        self.onLike = onLike
    }

    public var body: some View {
        ZStack {
            if let player = model.presentationPlayer {
                VideoPlayer(player: player)
                    .allowsHitTesting(false)
            } else {
                Color.black
            }

            PlayerInteractionSurface(
                onSingleTap: {
                    Task { await model.togglePlayback() }
                    model.revealControls()
                },
                onDoubleTap: {
                    onLike?()
                    model.revealControls()
                },
                onPressChanged: model.pressChanged,
                onPressCancelled: model.cancelPress
            )
            .accessibilityHidden(true)

            centerContent

            if model.shouldShowLowBandwidthWarning {
                VStack {
                    PlaybackLowBandwidthOverlay()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 76)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
        .animation(.easeInOut(duration: 0.2), value: model.areControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: model.shouldShowLowBandwidthWarning)
        .onAppear {
            model.startObserving()
            model.setMuted(isMuted ?? false)
            model.revealControls()
        }
        .task(id: isMuted) {
            model.setMuted(isMuted ?? false)
        }
        .task(id: model.hasPresentationPlayer) {
            if model.hasPresentationPlayer {
                model.setMuted(isMuted ?? false)
            }
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
        HStack(spacing: 12) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let isMuted, let onMuteToggle {
                Button(action: {
                    onMuteToggle()
                    model.revealControls()
                }) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            }
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


#if canImport(UIKit)
/// Transparent UIKit recognizers provide deterministic single-tap, double-tap,
/// and press-and-hold arbitration. A single tap waits for double-tap/long-press
/// recognition to fail, preventing a double tap from also toggling playback.
private struct PlayerInteractionSurface: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onPressChanged: (Bool) -> Void
    let onPressCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            onPressChanged: onPressChanged,
            onPressCancelled: onPressCancelled
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45

        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: longPress)
        doubleTap.require(toFail: longPress)

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            onPressChanged: onPressChanged,
            onPressCancelled: onPressCancelled
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.onPressCancelled()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onDoubleTap: () -> Void
        var onPressChanged: (Bool) -> Void
        var onPressCancelled: () -> Void

        init(
            onSingleTap: @escaping () -> Void,
            onDoubleTap: @escaping () -> Void,
            onPressChanged: @escaping (Bool) -> Void,
            onPressCancelled: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
            self.onPressChanged = onPressChanged
            self.onPressCancelled = onPressCancelled
        }

        func update(
            onSingleTap: @escaping () -> Void,
            onDoubleTap: @escaping () -> Void,
            onPressChanged: @escaping (Bool) -> Void,
            onPressCancelled: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
            self.onPressChanged = onPressChanged
            self.onPressCancelled = onPressCancelled
        }

        @objc func handleSingleTap() { onSingleTap() }
        @objc func handleDoubleTap() { onDoubleTap() }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onPressChanged(true)
            case .ended:
                onPressChanged(false)
            case .cancelled, .failed:
                onPressCancelled()
            default:
                break
            }
        }
    }
}
#elseif canImport(AppKit)
/// AppKit equivalent keeps the package buildable on its declared macOS target.
private struct PlayerInteractionSurface: NSViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onPressChanged: (Bool) -> Void
    let onPressCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            onPressChanged: onPressChanged,
            onPressCancelled: onPressCancelled
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        let singleTap = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfClicksRequired = 1

        let doubleTap = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfClicksRequired = 2

        let longPress = NSPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45

        singleTap.delegate = context.coordinator
        doubleTap.delegate = context.coordinator
        longPress.delegate = context.coordinator
        context.coordinator.setRecognizers(
            singleTap: singleTap,
            doubleTap: doubleTap,
            longPress: longPress
        )

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            onSingleTap: onSingleTap,
            onDoubleTap: onDoubleTap,
            onPressChanged: onPressChanged,
            onPressCancelled: onPressCancelled
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.onPressCancelled()
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var onSingleTap: () -> Void
        var onDoubleTap: () -> Void
        var onPressChanged: (Bool) -> Void
        var onPressCancelled: () -> Void
        private weak var singleTapRecognizer: NSClickGestureRecognizer?
        private weak var doubleTapRecognizer: NSClickGestureRecognizer?
        private weak var longPressRecognizer: NSPressGestureRecognizer?

        func setRecognizers(
            singleTap: NSClickGestureRecognizer,
            doubleTap: NSClickGestureRecognizer,
            longPress: NSPressGestureRecognizer
        ) {
            singleTapRecognizer = singleTap
            doubleTapRecognizer = doubleTap
            longPressRecognizer = longPress
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === singleTapRecognizer {
                return otherGestureRecognizer === doubleTapRecognizer
                    || otherGestureRecognizer === longPressRecognizer
            }
            if gestureRecognizer === doubleTapRecognizer {
                return otherGestureRecognizer === longPressRecognizer
            }
            return false
        }

        init(
            onSingleTap: @escaping () -> Void,
            onDoubleTap: @escaping () -> Void,
            onPressChanged: @escaping (Bool) -> Void,
            onPressCancelled: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
            self.onPressChanged = onPressChanged
            self.onPressCancelled = onPressCancelled
        }

        func update(
            onSingleTap: @escaping () -> Void,
            onDoubleTap: @escaping () -> Void,
            onPressChanged: @escaping (Bool) -> Void,
            onPressCancelled: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
            self.onPressChanged = onPressChanged
            self.onPressCancelled = onPressCancelled
        }

        @objc func handleSingleTap() { onSingleTap() }
        @objc func handleDoubleTap() { onDoubleTap() }

        @objc func handleLongPress(_ recognizer: NSPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onPressChanged(true)
            case .ended:
                onPressChanged(false)
            case .cancelled, .failed:
                onPressCancelled()
            default:
                break
            }
        }
    }
}
#endif

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

private struct PlaybackLowBandwidthOverlay: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
            Text("Weak connection. Video quality may be reduced.")
                .font(.subheadline)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("PlaybackLowBandwidthWarning")
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
