import AVFoundation
import ChirpAudio
import ChirpCore
import ChirpUI
import Observation
import SwiftUI

/// Plays a transcript's source media with `AVAudioPlayer`: play/pause, seek, and speed 1× → 1.5× → 2× → 0.75×.
/// The time readout polls the player while it plays; it never invents progress.
///
/// The audio session goes through the app's one `AudioSessionController` (never `AVAudioSession` directly), so a
/// dictation that starts pauses playback instead of fighting it. It pauses (and stays paused) on an interruption and
/// when headphones are unplugged, as Apple's playback guidelines ask.
@MainActor @Observable final class AudioPlayerModel {
    static let rates: [Float] = [1, 1.5, 2, 0.75]

    private(set) var isAvailable = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private let session: AudioSessionController
    @ObservationIgnored private var sessionObserver: AudioSessionController.ObserverToken?
    @ObservationIgnored private let logger = Log.logger("player")

    init(session: AudioSessionController) {
        self.session = session
        sessionObserver = session.observe(.playback) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    isolated deinit {
        if let sessionObserver { session.removeObserver(sessionObserver) }
    }

    private func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan, .routeChanged(.oldDeviceUnavailable), .mediaServicesLost, .mediaServicesReset:
            if isPlaying { pause() }
            if event == .mediaServicesReset || event == .interruptionBegan { sessionActive = false }
        case .interruptionEnded, .routeChanged:
            // Never auto-resume: the person presses play again.
            break
        }
    }

    /// Opens `url` (nil hides the player). Re-opening the same file keeps the position.
    func load(_ url: URL?) {
        guard url != loadedURL || player == nil else { return }
        stop()
        loadedURL = url
        player = nil
        guard let url else {
            isAvailable = false
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isAvailable = duration > 0
        } catch {
            // Some containers (e.g. certain videos) have no audio AVAudioPlayer can open: the text still shows.
            logger.error("player_open_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            isAvailable = false
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player, activateSession() else { return }
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.rate = rate
        let started = player.play()
        if started {
            isPlaying = true
            startTicker()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        if let player { currentTime = player.currentTime }
    }

    /// Stops playback and releases the audio session (leaving the screen).
    func stop() {
        pause()
        deactivateSession()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(seconds, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
    }

    /// "1×", "1.5×", "0.75×".
    static func label(for rate: Float) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", Double(rate))
        return text + "×"
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    // Reached the end (AVAudioPlayer stops by itself).
                    self.isPlaying = false
                    self.ticker = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// False when the session could not be had (for example while dictating); `play()` then does nothing.
    private func activateSession() -> Bool {
        do {
            try session.reactivate(for: .playback)
            sessionActive = true
            return true
        } catch {
            logger.error("session_activate_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        session.deactivate(for: .playback)
    }
}

/// The canvas player bar: coral play button, scrubber with current/total time, and the speed button.
struct PlayerBar: View {
    let player: AudioPlayerModel
    @State private var scrubFraction: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Tokens.Color.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            VStack(spacing: 8) {
                Scrubber(
                    fraction: shownFraction,
                    onChange: { scrubFraction = $0 },
                    onCommit: { fraction in
                        player.seek(to: fraction * player.duration)
                        scrubFraction = nil
                    }
                )
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(Formatting.clock(ms: shownMs)) of \(Formatting.clock(ms: Int(player.duration * 1000)))"
                )
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: player.skip(by: 5)
                    case .decrement: player.skip(by: -5)
                    @unknown default: break
                    }
                }
                HStack {
                    Text(Formatting.clock(ms: shownMs))
                    Spacer()
                    Text(Formatting.clock(ms: Int(player.duration * 1000)))
                }
                .chirpFont(11.5)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
                .accessibilityHidden(true)
            }

            Button {
                player.cycleRate()
            } label: {
                Text(AudioPlayerModel.label(for: player.rate))
                    .chirpFont(12.5, .bold)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.ink)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppColor.quietFill))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(AudioPlayerModel.label(for: player.rate))")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
        .background(CardBackground(radius: Tokens.Radius.m))
    }

    private var shownFraction: Double {
        if let scrubFraction { return scrubFraction }
        guard player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    private var shownMs: Int {
        Int(shownFraction * player.duration * 1000)
    }
}

/// A 6 pt track with an accent fill and a white thumb; drag or tap anywhere on it to seek.
private struct Scrubber: View {
    let fraction: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let x = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.quietFill).frame(height: 6)
                Capsule().fill(Tokens.Color.accent).frame(width: max(6, x), height: 6)
                Circle()
                    .fill(Tokens.Color.surface)
                    .overlay(Circle().strokeBorder(Tokens.Color.accent, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(x - 7, 0), width - 14))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onChange(Self.clamp(value.location.x / width)) }
                    .onEnded { value in onCommit(Self.clamp(value.location.x / width)) }
            )
        }
        .frame(height: 22)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
