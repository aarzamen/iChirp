import ChirpAudio
import ChirpCore
import ChirpFeatures
import ChirpIngest
import Foundation

// Plan 022 (Create): factories kept out of `AppEnvironment.swift` so parallel lanes touching the composition root
// merge cleanly. Everything here is built from services the environment already owns.

extension AppEnvironment {
    /// A voice-message maker for one voice message (Step 5). Voices, routing and the stored class exactly as Listen
    /// uses them: Settings → Voices' choice, only the Mac companion's own trust, `VoiceSourcePrivacy` before every chunk.
    func makeVoiceMessageExporter() -> VoiceMessageExporter {
        let engines = voiceEngines
        let settingsStore = UserDefaultsVoiceSettingsStore()
        let companion = companionConfiguration
        let store = self.store
        let deliverableStore = self.deliverableStore
        return VoiceMessageExporter(
            selection: { try settingsStore.load().selection(engines: engines) },
            routingPolicy: { VoicePlayer.routingPolicy(companion: companion.companionEndpoint()) },
            currentPrivacyClass: { source in
                await VoiceSourcePrivacy.current(for: source, transcripts: store, deliverables: deliverableStore)
            },
            writer: VoiceMessageWriter(), paths: paths)
    }
}

/// A Create input that could not start, in words (nothing was created).
struct CreateInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppEnvironment {
    /// A chain over this environment's services (Step 2's dependencies, wired to the real ones).
    func makeCreateFlow() -> CreateFlow {
        let store = self.store
        let jobCenter = self.jobCenter
        return CreateFlow(
            dependencies: CreateFlowDependencies(
                recordSpeech: { [unowned self] in await recordSpeechForCreate() },
                saveText: { text, privacyClass in
                    try await TextItemService(store: store).save(text, privacyClass: privacyClass)
                },
                startLink: { [unowned self] link, privacyClass in
                    try await startLinkForCreate(link, privacyClass: privacyClass)
                },
                startFile: { [unowned self] url, privacyClass in
                    try await startFileForCreate(url, privacyClass: privacyClass)
                },
                waitForItem: { id in
                    await jobCenter.waitForJob(id)
                    return try? await store.fetch(id: id)
                },
                retryItem: { [unowned self] id in await retryForCreate(id) },
                deliverables: deliverables,
                makeVoiceMessage: { [unowned self] in makeVoiceMessageExporter() }))
    }

    /// Speak: the ordinary dictation (the Dictating screen, its final pass, its clipboard copy and its row), followed
    /// until it is saved, discarded, or closed after a failure.
    private func recordSpeechForCreate() async -> CreateSpeechOutcome {
        await launch()
        guard dictation.state.isFinished else {
            return .failed(nil, "A dictation is still finishing. Try again when it is done.")
        }
        dictation.start()
        await dictation.waitForState { state in
            switch state {
            case .done, .cancelled, .failed: true
            default: false
            }
        }
        if case .failed = dictation.state {
            // The Dictating screen offers Retry (when audio was kept) and Close: follow the person's choice.
            let message = Self.failureMessage(dictation.state)
            await dictation.waitForState { $0 == .done || $0 == .idle || $0 == .cancelled }
            if dictation.state == .done, let id = dictation.transcriptionID { return .saved(id) }
            if dictation.state == .cancelled { return .discarded }
            return .failed(dictation.transcriptionID, message)
        }
        if dictation.state == .cancelled { return .discarded }
        guard let id = dictation.transcriptionID else {
            return .failed(nil, "The dictation was deleted before Parakeet could use it.")
        }
        return .saved(id)
    }

    private static func failureMessage(_ state: DictationFlowState) -> String {
        if case .failed(let message) = state { return message }
        return "The dictation did not finish."
    }

    /// Link: resolved on the person's tap (the only network use), then the same row and job as Paste a link. The row
    /// is created with the chain's class (review I1), so a Stop during the lookup never leaves it less private.
    private func startLinkForCreate(_ text: String, privacyClass: PrivacyClass) async throws -> UUID {
        await launch()
        let kind = LinkClassifier.classify(text)
        guard kind.isActionable else { throw CreateInputError(message: kind.detail) }
        let resolved: ResolvedLink
        do {
            resolved = try await linkIngest.resolve(kind)
        } catch {
            throw CreateInputError(message: Formatting.message(for: error))
        }
        switch resolved {
        case .media(let source):
            let id: UUID
            do {
                id = try await linkIngest.createRow(for: source, privacyClass: privacyClass)
            } catch {
                throw CreateInputError(message: Formatting.message(for: error))
            }
            let linkIngest = self.linkIngest
            let pipeline = self.pipeline
            jobCenter.startTracked(id, title: source.title ?? "Download") {
                await LinkIngestService.downloadThenTranscribe(await linkIngest.download(id: id, source: source)) {
                    await pipeline.process(id: id)
                }
            }
            return id
        case .youtubeCaptions(let videoID, let link):
            do {
                return try await linkIngest.importCaptions(videoID: videoID, link: link, privacyClass: privacyClass)
            } catch {
                let reason = Formatting.message(for: error)
                guard linkIngest.isCompanionConfigured() else { throw CreateInputError(message: reason) }
                throw CreateInputError(
                    message: reason + " To get its audio from your Mac instead, use Capture → Paste a link.")
            }
        }
    }

    /// File: audio and video go to the transcription pipeline (automatic audio track), documents to the reader; both
    /// as tracked jobs with their own background request, exactly like the Import tiles. The row is created with the
    /// chain's class (review I1), so a Stop during the copy never leaves it less private.
    private func startFileForCreate(_ url: URL, privacyClass: PrivacyClass) async throws -> UUID {
        await launch()
        let title = url.deletingPathExtension().lastPathComponent
        do {
            switch IncomingFileInbox.kind(of: url) {
            case .document:
                let documents = self.documents
                let id = try await documents.importItem(from: url, privacyClass: privacyClass)
                jobCenter.startTracked(id, title: title) { await documents.process(id: id) }
                return id
            case .media:
                let pipeline = self.pipeline
                let id = try await pipeline.importFile(from: url, privacyClass: privacyClass)
                jobCenter.startTracked(id, title: title) { await pipeline.process(id: id) }
                return id
            }
        } catch {
            throw CreateInputError(message: Formatting.message(for: error))
        }
    }

    /// Retry for a chain's item, by what the row is (the Library's Retry for everything but a dictation, whose final
    /// pass is awaited here).
    private func retryForCreate(_ id: UUID) async {
        guard let row = try? await store.fetch(id: id) else { return }
        switch row.sourceType {
        case .dictation:
            _ = await dictation.retry(transcriptionID: id)
        case .document:
            jobCenter.retry(id, title: row.displayTitle, importer: documents)
        default:
            retry(id)
        }
    }
}

extension AppEnvironment {
    /// Edit by voice (Step 4): a spoken instruction through the dictation path's final pass, on its own recorder over
    /// the shared microphone (a dictation or meeting in progress makes it say so instead). Review I2: it gets the
    /// speech router and uses the final route's engine (resolved once per instruction), like every other final pass;
    /// Parakeet is never loaded for it while it is on no route.
    func makeInstructionRecorder() -> SpokenInstructionRecorder {
        let rules = textRules
        return SpokenInstructionRecorder(
            capture: DictationRecorder(stream: microphone, session: audioSession), speech: speechRouter,
            scheduler: scheduler, settings: settings, textRules: { await rules.enabledRules() })
    }

    /// The versions of a generated document (Step 4).
    func makeDocumentVersionsViewModel(id: UUID) -> DocumentVersionsViewModel {
        DocumentVersionsViewModel(deliverableID: id, documents: deliverableStore, store: deliverableStore)
    }
}
