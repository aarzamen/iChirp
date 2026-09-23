import ChirpCore
import Foundation

/// One voice message to make: the text to speak, what it is (for routing and logs) and the item whose media folder
/// keeps the file (`media/<itemID>/voice-<n>.m4a`).
public struct VoiceMessageRequest: Sendable, Equatable {
    /// The words to speak (already `SpeakableText.prepare`d by the caller).
    public var text: String
    /// The class the caller knows; routing uses the stricter of it and the source's class as stored at every check.
    public var privacyClass: PrivacyClass
    /// What is spoken: a transcript, a document or text item, or a generated document.
    public var source: VoiceSource
    /// The Library item whose folder keeps the file (a generated document's transcript).
    public var itemID: UUID
    /// The share sheet's file title, e.g. the item's title.
    public var title: String

    public init(text: String, privacyClass: PrivacyClass, source: VoiceSource, itemID: UUID, title: String) {
        self.text = text
        self.privacyClass = privacyClass
        self.source = source
        self.itemID = itemID
        self.title = title
    }
}

/// A finished voice message on disk.
public struct VoiceMessageFile: Sendable, Equatable {
    /// Absolute URL of `media/<itemID>/voice-<n>.m4a`.
    public var url: URL
    /// Relative to `AppPaths.root`.
    public var relativePath: String
    /// The audio's length, when the writer measured it.
    public var durationMs: Int?
    public var chunkCount: Int

    public init(url: URL, relativePath: String, durationMs: Int?, chunkCount: Int) {
        self.url = url
        self.relativePath = relativePath
        self.durationMs = durationMs
        self.chunkCount = chunkCount
    }
}

/// Where making a voice message is. Progress is real: chunks synthesized so far out of the total.
public enum VoiceMessagePhase: Sendable, Equatable {
    case idle
    /// Checking the voice and routing; nothing sent yet.
    case preparing
    /// Clinical text bound for a cloud voice or an untrusted Mac: the dialog asks (per voice message, never remembered).
    case needsConfirmation(VoiceConfirmationRequest)
    /// `done` of `total` chunks synthesized.
    case synthesizing(done: Int, total: Int)
    /// Joining the chunks into one `.m4a`.
    case assembling
    case finished(VoiceMessageFile)
    /// A sentence to show, with Retry.
    case failed(String)
}

/// Makes one voice message at a time (Step 5's `VoiceMessageExporter`; fakes in tests). **Only the confirmation
/// dialog's button confirms a clinical question** (the app's `VoiceMessageConfirmationActions`); a chain such as
/// `CreateFlow` waits for `onAnswered` instead.
@MainActor public protocol VoiceMessageProducing: AnyObject {
    var phase: VoiceMessagePhase { get }
    /// Called after the person answered the clinical question (made, failed, asked again, or back to `.idle` after
    /// Cancel).
    var onAnswered: (@MainActor () -> Void)? { get set }
    /// Returns once the file is written, the question is asked, or it failed.
    func start(_ request: VoiceMessageRequest) async
    /// After a failure: again from the chunk that failed (a clinical cloud voice asks again).
    func retry() async
    /// Stops at once; nothing more is sent and no file is kept.
    func cancel()
}
