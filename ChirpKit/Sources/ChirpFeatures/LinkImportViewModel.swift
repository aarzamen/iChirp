import ChirpCore
import ChirpIngest
import Foundation
import Observation

/// The Paste a link sheet (M5 Step 6): the pasted text, what kind of link it is (decided locally, as the person types),
/// and the one explicit action that uses the network, `transcribe()`.
///
/// Podcast and media links become a Library row at once and continue as a tracked job (download, then transcription)
/// that outlives the sheet; YouTube links fetch captions while the sheet waits and then become a finished row. Errors
/// before a row exists stay in the sheet; nothing is created for them.
@MainActor @Observable public final class LinkImportViewModel {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the person.
        case editing
        /// Resolving the link (network), with a short description of what is happening.
        case working(String)
        /// The row exists: it is downloading and transcribing as a job, or (YouTube) already finished.
        case started(UUID)
        /// Nothing was created; the message says why.
        case failed(String)
    }

    /// The pasted or typed text. Classified locally on every change; the network is never touched here.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            kind = LinkClassifier.classify(text)
            if case .failed = phase { phase = .editing }
        }
    }

    public private(set) var kind: LinkKind = .unsupported(.empty)
    public private(set) var phase: Phase = .editing

    /// Whether a lookup or caption fetch is running.
    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// Whether Transcribe is enabled: an actionable link and nothing running.
    public var canTranscribe: Bool {
        guard kind.isActionable else { return false }
        switch phase {
        case .editing, .failed: return true
        case .working, .started: return false
        }
    }

    /// The row started by the last Transcribe, if any.
    public var startedID: UUID? {
        if case .started(let id) = phase { return id }
        return nil
    }

    @ObservationIgnored private let service: LinkIngestService
    @ObservationIgnored private let startMediaJob: @MainActor (UUID, LinkMediaSource) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameter startMediaJob: runs a new link row's download and transcription as a tracked job (the app wires
    ///   `TranscriptionJobCenter.startTracked` with `LinkIngestService.download` and the file pipeline).
    public init(service: LinkIngestService, startMediaJob: @escaping @MainActor (UUID, LinkMediaSource) -> Void) {
        self.service = service
        self.startMediaJob = startMediaJob
    }

    isolated deinit {
        task?.cancel()
    }

    /// The person's tap: resolves the link (the only network use), then creates the row. Does nothing unless
    /// `canTranscribe`.
    public func transcribe() {
        guard canTranscribe else { return }
        let kind = self.kind
        phase = .working(Self.workingMessage(for: kind))
        let service = self.service
        task = Task { [weak self] in
            do {
                let resolved = try await service.resolve(kind)
                try Task.checkCancellation()
                switch resolved {
                case .media(let source):
                    let id = try await service.createRow(for: source)
                    self?.startMediaJob(id, source)
                    self?.phase = .started(id)
                case .youtubeCaptions(let videoID, let link):
                    self?.phase = .working("Fetching the captions from YouTube…")
                    let id = try await service.importCaptions(videoID: videoID, link: link)
                    self?.phase = .started(id)
                }
            } catch is CancellationError {
                self?.phase = .editing
            } catch {
                self?.phase = .failed(LinkIngestService.readable(error))
            }
        }
    }

    /// Stops a running lookup (a started job is cancelled from the Library instead).
    public func cancel() {
        task?.cancel()
    }

    /// Clears the field for another link.
    public func reset() {
        task?.cancel()
        task = nil
        text = ""
        phase = .editing
    }

    /// Waits for the running lookup to end (tests).
    public func waitUntilSettled() async {
        await task?.value
    }

    static func workingMessage(for kind: LinkKind) -> String {
        switch kind {
        case .applePodcastEpisode: "Finding the episode on Apple Podcasts…"
        case .applePodcastShow: "Finding the latest episode…"
        case .podcastFeed: "Reading the podcast feed…"
        case .directMedia: "Starting the download…"
        case .youtube: "Fetching the captions from YouTube…"
        case .webLink: "Checking what the link is…"
        case .unsupported: ""
        }
    }
}
