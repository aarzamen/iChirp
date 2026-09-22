import Foundation
import SwiftUI
import MacParakeetCore

/// Cross-process state exchange model for iOS Keyboard Extension dictation.
///
/// Due to iOS Keyboard Extensions having a strict ~30MB Jetsam memory limit,
/// CoreML models cannot be loaded directly inside the keyboard extension process.
/// This state model coordinates communication between the keyboard UI and the host application.
public struct KeyboardDictationState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case idle
        case requesting
        case recording
        case transcribing
        case finished
        case error
    }

    public var status: Status
    public var partialTranscript: String
    public var finalTranscript: String
    public var audioLevel: Float
    public var errorMessage: String?
    public var timestamp: Date

    public init(
        status: Status = .idle,
        partialTranscript: String = "",
        finalTranscript: String = "",
        audioLevel: Float = 0.0,
        errorMessage: String? = nil,
        timestamp: Date = Date()
    ) {
        self.status = status
        self.partialTranscript = partialTranscript
        self.finalTranscript = finalTranscript
        self.audioLevel = audioLevel
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

/// Client-side coordinator running inside the iOS Keyboard Extension (`UIInputViewController`).
@Observable
@MainActor
public final class KeyboardDictationClient {
    public var currentState: KeyboardDictationState = .init()
    public var onFinalTextReady: (@Sendable (String) -> Void)?
    public var onPartialTextUpdated: (@Sendable (String) -> Void)?

    @ObservationIgnored
    nonisolated(unsafe) private var observerToken: UUID?
    @ObservationIgnored
    private let stateKey = "ParakeetKeyboardDictationState"

    public init() {
        loadState()
        setupNotificationObserver()
    }

    deinit {
        if let token = observerToken {
            DarwinNotificationBroadcaster.shared.removeObserver(token)
        }
    }

    /// Requests the host app to start voice recording and live transcription.
    public func startDictation() {
        let state = KeyboardDictationState(status: .requesting, timestamp: Date())
        saveState(state)
        currentState = state
        DarwinNotificationBroadcaster.shared.post(AppGroupConstants.keyboardStartNotification)
    }

    /// Requests the host app to stop recording and finalize transcription.
    public func stopDictation() {
        var state = currentState
        state.status = .transcribing
        state.timestamp = Date()
        saveState(state)
        currentState = state
        DarwinNotificationBroadcaster.shared.post(AppGroupConstants.keyboardStopNotification)
    }

    /// Cancels active dictation and returns to idle state.
    public func cancelDictation() {
        let state = KeyboardDictationState(status: .idle, timestamp: Date())
        saveState(state)
        currentState = state
        DarwinNotificationBroadcaster.shared.post(AppGroupConstants.keyboardStopNotification)
    }

    private func setupNotificationObserver() {
        observerToken = DarwinNotificationBroadcaster.shared.observe(
            AppGroupConstants.keyboardStateChangedNotification
        ) { [weak self] in
            Task { @MainActor in
                self?.handleRemoteStateChange()
            }
        }
    }

    private func handleRemoteStateChange() {
        loadState()
        if !currentState.partialTranscript.isEmpty {
            onPartialTextUpdated?(currentState.partialTranscript)
        }
        if currentState.status == .finished && !currentState.finalTranscript.isEmpty {
            onFinalTextReady?(currentState.finalTranscript)
            // Reset to idle after handing off text
            var idleState = currentState
            idleState.status = .idle
            saveState(idleState)
            currentState = idleState
        }
    }

    private func loadState() {
        guard let data = AppGroupConstants.sharedUserDefaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(KeyboardDictationState.self, from: data) else {
            return
        }
        self.currentState = decoded
    }

    private func saveState(_ state: KeyboardDictationState) {
        if let encoded = try? JSONEncoder().encode(state) {
            AppGroupConstants.sharedUserDefaults.set(encoded, forKey: stateKey)
        }
    }
}

/// Server-side coordinator running inside the host application to service keyboard dictation requests.
public final class KeyboardDictationServer: @unchecked Sendable {
    public static let shared = KeyboardDictationServer()

    private let stateKey = "ParakeetKeyboardDictationState"
    private var startObserverToken: UUID?
    private var stopObserverToken: UUID?

    public var onStartRequested: (@Sendable () -> Void)?
    public var onStopRequested: (@Sendable () -> Void)?

    private init() {
        setupObservers()
    }

    deinit {
        if let token = startObserverToken {
            DarwinNotificationBroadcaster.shared.removeObserver(token)
        }
        if let token = stopObserverToken {
            DarwinNotificationBroadcaster.shared.removeObserver(token)
        }
    }

    private func setupObservers() {
        startObserverToken = DarwinNotificationBroadcaster.shared.observe(
            AppGroupConstants.keyboardStartNotification
        ) { [weak self] in
            self?.onStartRequested?()
        }

        stopObserverToken = DarwinNotificationBroadcaster.shared.observe(
            AppGroupConstants.keyboardStopNotification
        ) { [weak self] in
            self?.onStopRequested?()
        }
    }

    /// Updates the state and broadcasts it to the keyboard extension.
    public func updateState(
        status: KeyboardDictationState.Status,
        partialTranscript: String = "",
        finalTranscript: String = "",
        audioLevel: Float = 0.0,
        errorMessage: String? = nil
    ) {
        let state = KeyboardDictationState(
            status: status,
            partialTranscript: partialTranscript,
            finalTranscript: finalTranscript,
            audioLevel: audioLevel,
            errorMessage: errorMessage,
            timestamp: Date()
        )

        if let encoded = try? JSONEncoder().encode(state) {
            AppGroupConstants.sharedUserDefaults.set(encoded, forKey: stateKey)
            DarwinNotificationBroadcaster.shared.post(AppGroupConstants.keyboardStateChangedNotification)
        }
    }
}

/// SwiftUI banner view that renders inside the iOS Keyboard Extension to show live dictation controls.
public struct KeyboardDictationBannerView: View {
    @Bindable public var client: KeyboardDictationClient

    public init(client: KeyboardDictationClient) {
        self.client = client
    }

    public var body: some View {
        HStack(spacing: MobileDesignSystem.Spacing.md) {
            switch client.currentState.status {
            case .idle:
                Button(action: {
                    PlatformHaptics.trigger(.medium)
                    client.startDictation()
                }) {
                    HStack(spacing: MobileDesignSystem.Spacing.sm) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(MobileDesignSystem.Colors.accent)

                        Text("Tap to Dictate")
                            .font(MobileDesignSystem.Typography.subheadline)
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    }
                    .padding(.horizontal, MobileDesignSystem.Spacing.md)
                    .padding(.vertical, MobileDesignSystem.Spacing.sm)
                    .background(MobileDesignSystem.Colors.accentLight)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

            case .requesting, .recording:
                HStack(spacing: MobileDesignSystem.Spacing.sm) {
                    Circle()
                        .fill(MobileDesignSystem.Colors.accent)
                        .frame(width: 10, height: 10)

                    if client.currentState.partialTranscript.isEmpty {
                        Text("Listening...")
                            .font(MobileDesignSystem.Typography.subheadline)
                            .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    } else {
                        Text(client.currentState.partialTranscript)
                            .font(MobileDesignSystem.Typography.subheadline)
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Cancel Button
                Button(action: {
                    PlatformHaptics.trigger(.light)
                    client.cancelDictation()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)

                // Done / Stop Button
                Button(action: {
                    PlatformHaptics.trigger(.success)
                    client.stopDictation()
                }) {
                    Text("Done")
                        .font(MobileDesignSystem.Typography.headline)
                        .foregroundColor(MobileDesignSystem.Colors.accent)
                        .padding(.horizontal, MobileDesignSystem.Spacing.sm)
                }
                .buttonStyle(.plain)

            case .transcribing:
                HStack(spacing: MobileDesignSystem.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Processing speech...")
                        .font(MobileDesignSystem.Typography.subheadline)
                        .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                }

                Spacer()

            case .finished:
                HStack(spacing: MobileDesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(MobileDesignSystem.Colors.successGreen)

                    Text("Inserted")
                        .font(MobileDesignSystem.Typography.subheadline)
                        .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                }

                Spacer()

            case .error:
                HStack(spacing: MobileDesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(MobileDesignSystem.Colors.warningAmber)

                    Text(client.currentState.errorMessage ?? "Dictation error")
                        .font(MobileDesignSystem.Typography.caption)
                        .foregroundColor(MobileDesignSystem.Colors.errorRed)
                        .lineLimit(1)
                }

                Spacer()

                Button("Retry") {
                    client.startDictation()
                }
                .font(MobileDesignSystem.Typography.caption)
                .foregroundColor(MobileDesignSystem.Colors.accent)
            }
        }
        .padding(.horizontal, MobileDesignSystem.Spacing.md)
        .padding(.vertical, MobileDesignSystem.Spacing.xs)
        .frame(height: 44)
        .background(MobileDesignSystem.Colors.surface)
    }
}
