import ChirpCore
import Foundation
import Observation

/// Speaks text aloud for the "read back" command. The app connects it to plan 020's `VoicePlayer` through
/// `ReadBackRelay`; the dictation's id travels along so the player routes every chunk on that transcript's current
/// (effective) privacy class.
public protocol ReadBackSpeaking: Sendable {
    /// Whether a voice is set up at all (the chip says "no voice set up" otherwise). Read on the main actor, where
    /// voice settings live.
    @MainActor var isAvailable: Bool { get }
    func readBack(_ text: String, transcriptionID: UUID) async
}

/// The no-op default: no voice output is wired.
public struct SilentReadBack: ReadBackSpeaking {
    public init() {}
    @MainActor public var isAvailable: Bool { false }
    public func readBack(_ text: String, transcriptionID: UUID) async {}
}

/// A read-back target connected after construction (the app builds dictation before the voice player). Until
/// `connect` is called it behaves like `SilentReadBack`.
public final class ReadBackRelay: ReadBackSpeaking, @unchecked Sendable {
    private let lock = NSLock()
    private var availability: (@MainActor @Sendable () -> Bool)?
    private var speaker: (@Sendable (String, UUID) async -> Void)?

    public init() {}

    public func connect(
        isAvailable: @escaping @MainActor @Sendable () -> Bool,
        speak: @escaping @Sendable (String, UUID) async -> Void
    ) {
        lock.withLock {
            availability = isAvailable
            speaker = speak
        }
    }

    @MainActor public var isAvailable: Bool {
        let check = lock.withLock { availability }
        return check?() ?? false
    }

    public func readBack(_ text: String, transcriptionID: UUID) async {
        let speak = lock.withLock { speaker }
        await speak?(text, transcriptionID)
    }
}

/// What the Dictating screen should open after the copy ("send to SOAP", "send to Transform").
public struct PendingDictationTransform: Sendable, Equatable, Identifiable {
    public enum Target: Sendable, Equatable {
        /// The SOAP template, on the on-device model.
        case soap
        /// The Transform picker.
        case picker
    }

    public var id: UUID { transcriptionID }
    public var transcriptionID: UUID
    public var target: Target

    public init(transcriptionID: UUID, target: Target) {
        self.transcriptionID = transcriptionID
        self.target = target
    }
}

/// A command heard in the live preview (display only; it never edits the live text).
public struct VoiceCommandChip: Sendable, Equatable {
    public var command: String
    /// "New paragraph", "Scratch that", …
    public var title: String
    public var confidence: Double
    public var isStub: Bool

    public init(command: String, title: String, confidence: Double, isStub: Bool) {
        self.command = command
        self.title = title
        self.confidence = confidence
        self.isStub = isStub
    }
}

/// The dictation coordinator's voice-command hooks. `DictationVoiceCommands` in the app; nil when unused.
@MainActor public protocol DictationVoiceCommanding: AnyObject {
    /// Called for a live "stop" command at the act threshold.
    var onLiveStop: (@MainActor () -> Void)? { get set }
    /// A new dictation starts.
    func reset()
    /// The live preview changed (display text only).
    func observeLive(_ text: String)
    /// The final pass's text with commands applied (unchanged when voice commands are off).
    func applyToFinalPass(_ text: String) async -> VoiceCommandResult
    /// Runs the non-text effects after the copy.
    func perform(_ actions: [VoiceCommandAction], copiedText: String, transcriptionID: UUID)
}

/// Voice commands for dictation (Settings → Structure models → Voice commands, off by default).
///
/// Live: after a pause (`pauseSeconds` without a preview change), the trailing words are checked; a command at the
/// act threshold shows as a chip. Final: `VoiceCommandResolver` on the final pass. The engine is Needle when it can
/// run, otherwise the STUB, and the chip says STUB.
@MainActor @Observable public final class DictationVoiceCommands: DictationVoiceCommanding {
    public private(set) var chip: VoiceCommandChip?
    /// The last final pass's applied and ignored commands (for the Done screen and QA).
    public private(set) var lastResult: VoiceCommandResult?
    public private(set) var pendingTransform: PendingDictationTransform?
    /// Set when "read back" was said but no voice is set up.
    public private(set) var readBackUnavailable = false
    @ObservationIgnored public var onLiveStop: (@MainActor () -> Void)?

    @ObservationIgnored private let settings: any StructureSettingsStoring
    @ObservationIgnored private let engines: StructureEngines
    @ObservationIgnored private let readBack: any ReadBackSpeaking
    @ObservationIgnored private let pauseSeconds: Double
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    public init(
        settings: any StructureSettingsStoring, engines: StructureEngines,
        readBack: any ReadBackSpeaking = SilentReadBack(), pauseSeconds: Double = 0.9
    ) {
        self.settings = settings
        self.engines = engines
        self.readBack = readBack
        self.pauseSeconds = pauseSeconds
    }

    public var isEnabled: Bool { settings.load().voiceCommandsEnabled }

    public func reset() {
        liveTask?.cancel()
        liveTask = nil
        chip = nil
        lastResult = nil
        readBackUnavailable = false
    }

    public func observeLive(_ text: String) {
        guard isEnabled else { return }
        liveTask?.cancel()
        let pause = pauseSeconds
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(pause))
            guard !Task.isCancelled else { return }
            await self?.checkLive(text)
        }
    }

    private func checkLive(_ text: String) async {
        let resolver = await makeResolver()
        guard let match = await resolver.liveCommand(in: text), !Task.isCancelled else { return }
        chip = VoiceCommandChip(
            command: match.command, title: Self.title(for: match.command), confidence: match.confidence,
            isStub: match.engineID == StubStructureModel.engineID)
        if match.command == "stop" { onLiveStop?() }
    }

    public func applyToFinalPass(_ text: String) async -> VoiceCommandResult {
        liveTask?.cancel()
        guard isEnabled else { return .unchanged(text) }
        let result = await makeResolver().resolve(text)
        lastResult = result
        return result
    }

    public func perform(_ actions: [VoiceCommandAction], copiedText: String, transcriptionID: UUID) {
        for action in actions {
            switch action {
            case .readBack:
                if readBack.isAvailable {
                    let readBack = self.readBack
                    Task { await readBack.readBack(copiedText, transcriptionID: transcriptionID) }
                } else {
                    readBackUnavailable = true
                }
            case .sendToSOAP:
                pendingTransform = PendingDictationTransform(transcriptionID: transcriptionID, target: .soap)
            case .sendToTransform:
                pendingTransform = PendingDictationTransform(transcriptionID: transcriptionID, target: .picker)
            }
        }
    }

    /// The Dictating screen opened (or dismissed) the pending Transform.
    public func consumePendingTransform() { pendingTransform = nil }

    private func makeResolver() async -> VoiceCommandResolver {
        let value = settings.load()
        let engine = await engines.resolve(value.engine).model
        return VoiceCommandResolver(engine: engine, gate: value.gate)
    }

    public static func title(for command: String) -> String {
        switch command {
        case "new_paragraph": "New paragraph"
        case "new_line": "New line"
        case "bullet_list": "Bullet list"
        case "scratch_that": "Scratch that"
        case "undo": "Undo"
        case "capitalize": "Capitalize"
        case "read_back": "Read back"
        case "send_to_soap": "Send to SOAP"
        case "send_to_transform": "Send to Transform"
        case "stop": "Stop"
        default: command
        }
    }
}
