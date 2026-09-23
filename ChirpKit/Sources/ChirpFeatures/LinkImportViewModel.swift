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
///
/// Plan 019: when a YouTube video has no usable captions and a Mac companion is set up, the sheet offers "Get the
/// audio from your Mac" (`companionOffer`). The person confirms once per link that the link leaves this iPhone for
/// their Mac; the audio then comes back as a normal link job (download, then transcription on this iPhone).
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
        /// The video has no usable captions and a Mac companion is set up: the message says so, and
        /// `getAudioFromMac()` is offered (after the person confirms sending the link to their Mac).
        case companionOffer(String)
    }

    /// The pasted or typed text. Classified locally on every change; the network is never touched here.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            kind = LinkClassifier.classify(text)
            switch phase {
            case .failed, .companionOffer:
                phase = .editing
                companionLink = nil
            case .editing, .working, .started:
                break
            }
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
        case .working, .started, .companionOffer: return false
        }
    }

    /// The row started by the last Transcribe, if any.
    public var startedID: UUID? {
        if case .started(let id) = phase { return id }
        return nil
    }

    /// The YouTube link the companion offer is about.
    public private(set) var companionLink: URL?

    /// Whether `getAudioFromMac()` must be confirmed first: the person has not yet agreed to send this link to their
    /// Mac in this sheet (asked once per link).
    public var needsCompanionConfirmation: Bool {
        guard let companionLink else { return false }
        return !confirmedCompanionLinks.contains(companionLink.absoluteString)
    }

    @ObservationIgnored private let service: LinkIngestService
    @ObservationIgnored private let startMediaJob: @MainActor (UUID, LinkMediaSource) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmedCompanionLinks: Set<String> = []

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
                    do {
                        let id = try await service.importCaptions(videoID: videoID, link: link)
                        self?.phase = .started(id)
                    } catch let error as YouTubeCaptionError where Self.companionCanHelp(error) {
                        self?.offerCompanion(for: link, captionsError: error)
                    }
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

    /// The person agreed to send `companionLink` to their Mac (the sheet's confirmation). Remembered for this link.
    public func confirmCompanion() {
        guard let companionLink else { return }
        confirmedCompanionLinks.insert(companionLink.absoluteString)
    }

    /// "Get the audio from your Mac": creates the row and starts its job (the companion downloads, this iPhone
    /// transcribes). Does nothing until the person confirmed this link (`needsCompanionConfirmation`).
    public func getAudioFromMac() {
        guard case .companionOffer = phase, let link = companionLink, !needsCompanionConfirmation else { return }
        let source = LinkMediaSource.companionYouTube(link)
        phase = .working("Asking your Mac for the audio…")
        let service = self.service
        task = Task { [weak self] in
            do {
                let id = try await service.createRow(for: source)
                self?.startMediaJob(id, source)
                self?.phase = .started(id)
            } catch is CancellationError {
                self?.phase = .editing
            } catch {
                self?.phase = .failed(LinkIngestService.readable(error))
            }
        }
    }

    /// Caption failures the Mac companion can get around by fetching the audio itself.
    static func companionCanHelp(_ error: YouTubeCaptionError) -> Bool {
        switch error {
        case .noCaptions, .emptyTranscript, .tokenRequired, .pageChanged, .blocked, .consentRequired: true
        case .videoUnavailable, .ageRestricted, .unplayable: false
        }
    }

    private func offerCompanion(for link: URL, captionsError: YouTubeCaptionError) {
        let reason = Self.captionsReason(captionsError)
        if service.isCompanionConfigured() {
            companionLink = link
            phase = .companionOffer(reason)
        } else {
            phase = .failed(
                "\(reason) To transcribe its audio instead, set up the Mac companion in Settings → Mac companion.")
        }
    }

    /// A short sentence about why there are no captions (without the "share the file" advice the full error adds).
    static func captionsReason(_ error: YouTubeCaptionError) -> String {
        switch error {
        case .noCaptions, .emptyTranscript: "This video has no captions."
        case .tokenRequired, .blocked, .consentRequired, .pageChanged:
            "YouTube wouldn’t give Parakeet this video’s captions."
        case .videoUnavailable, .ageRestricted, .unplayable: error.errorDescription ?? ""
        }
    }

    /// Clears the field for another link.
    public func reset() {
        task?.cancel()
        task = nil
        text = ""
        companionLink = nil
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
