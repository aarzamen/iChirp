import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// Tab 1 (canvas `Home.dc.html`, plan 022 redesign): the header (with a chip that says where things run, true for the
/// current settings), the **Create** card (the primary action: anything in, anything out), the shortcuts (Dictate, Type
/// or paste, Paste a link, Import a file), Record Meeting, and the three most recent items.
struct CaptureScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let openTab: (AppTab) -> Void

    @State private var path: [UUID] = []
    @State private var placeholder: Placeholder?
    @State private var isImporting = false
    @State private var pickerError: String?
    /// M5: the Paste a link sheet.
    @State private var isPastingLink = false
    /// Plan 022: the Type or paste sheet.
    @State private var isTyping = false
    /// UX audit F13: the "Where things run" sheet behind the header chip.
    @State private var isShowingReach = false
    /// Bumped when the screen appears, so the chip re-reads settings that are not observed (the Mac companion's trust).
    @State private var reachRefresh = 0

    /// Audio and video (the transcription pipeline's inputs).
    static let importTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if environment.isLaunched, !environment.isSpeechModelReady {
                        // M7 (review I2): the final route's engine, which may not be Parakeet.
                        let model = environment.finalSpeechModel
                        ModelMissingBanner(
                            engineName: model.name, status: model.status, isParakeet: model.isParakeet
                        ) {
                            openTab(.settings)
                        }
                    }
                    createCard
                    SectionLabel("Shortcuts", size: 12.5)
                        .padding(.top, 4)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14
                    ) {
                        dictateTile
                        tile(
                            title: "Type or paste", subtitle: "Notes, any text",
                            systemImage: "text.cursor", action: { isTyping = true })
                        // One wording for links everywhere (UX audit F16); files of every kind come in through Import.
                        tile(
                            title: "Paste a link", subtitle: "Podcast, YouTube, web link", systemImage: "link",
                            action: { isPastingLink = true })
                        tile(
                            title: "Import a file", subtitle: "Voice Memos, audio, PDF, Word",
                            systemImage: "square.and.arrow.down", action: { isImporting = true })
                    }
                    recordMeetingRow
                    recentHeader
                        .padding(.top, 4)
                    recentList
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                LibraryItemScreen(id: id, environment: environment)
            }
        }
        .sheet(isPresented: $isPastingLink) {
            PasteLinkSheet(environment: environment) { id in path.append(id) }
        }
        .sheet(isPresented: $isTyping) {
            TextItemSheet { id in path.append(id) }
        }
        .ingestPreviewLaunch(environment: environment, isPastingLink: $isPastingLink, path: $path)
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: CreateFileTypes.all, allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
        .sheet(isPresented: $isShowingReach) {
            WhereThingsRunSheet(reach: reach) { openTab(.settings) }
        }
        .onAppear { reachRefresh += 1 }
        .alert(
            "Couldn’t import that file",
            isPresented: Binding(
                get: { environment.jobCenter.lastImportError != nil || pickerError != nil },
                set: { presented in
                    if !presented {
                        environment.jobCenter.dismissImportError()
                        pickerError = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.jobCenter.lastImportError ?? pickerError ?? "")
        }
    }

    /// Audio and video go to the transcription pipeline, documents (PDF, Word, text) to the reader, as when another app
    /// shares them.
    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            let split = Self.splitImports(urls)
            if !split.media.isEmpty { environment.importFiles(split.media) }
            if !split.documents.isEmpty { environment.importDocuments(split.documents) }
        case .failure(let error):
            pickerError = Formatting.message(for: error)
        }
    }

    /// Picked files by where they go: the transcription pipeline or the document reader.
    static func splitImports(_ urls: [URL]) -> (media: [URL], documents: [URL]) {
        (
            urls.filter { IncomingFileInbox.kind(of: $0) == .media },
            urls.filter { IncomingFileInbox.kind(of: $0) == .document }
        )
    }

    /// Where the configured routes send content now (UX audit F13).
    private var reach: ContentReach {
        _ = reachRefresh
        return ContentReach.current(
            speechEngineName: environment.finalSpeechModel.name,
            defaultModel: environment.languageModels.defaultChoice,
            otherProviders: environment.languageModels.choices,
            voice: environment.voiceSettings.settings.provider,
            companionTrusted: environment.companionConfiguration.companionEndpoint()?.isTrusted ?? false,
            jevEnabled: environment.jevSettingsModel.isEnabled)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ParakeetMarkView()
                .frame(width: 27, height: 27)
            Text("Parakeet")
                .chirpTitleFont(22)
                .foregroundStyle(Tokens.Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ContentReachChip(reach: reach) { isShowingReach = true }
        }
        .frame(minHeight: 44)
    }

    // MARK: - Create (plan 022)

    /// The primary action. While a chain runs behind "Hide", the card shows its real progress and brings it back.
    private var createCard: some View {
        let create = environment.create
        // A chain exists until Done: running, waiting for an answer, or finished and not yet looked at.
        let running = create.flow != nil
        return Button {
            create.open()
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Tokens.Color.accent)
                        .shadow(color: Tokens.Color.accent.opacity(0.32), radius: 8, y: 6)
                    Image(systemName: running ? "sparkles" : "plus")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(running ? Self.createTitle(create) : "Create")
                        .chirpTitleFont(23)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(
                        running
                            ? Self.createStatus(create, progress: environment.jobCenter.progress)
                            : "Speak, type, paste a link or pick a file. Get a transcript, summary, document or voice message."
                    )
                    .chirpFont(13.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if running {
                        Text(create.flow?.isActive == true ? "Return" : "See the result")
                            .chirpFont(13.5, .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 30)
                            .background(Capsule().fill(Tokens.Color.accentFill))
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.xl, fill: AppColor.tintFill, stroke: AppColor.tintStroke))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            running ? "Returns to what Parakeet is creating." : "Choose what you have and what you want.")
    }

    /// "Creating: Speak → Summary", "Created", "Stopped".
    static func createTitle(_ create: CreateHost) -> String {
        switch create.flow?.phase {
        case .finished?: "Created"
        case .failed?, .cancelled?: "Stopped"
        case .waitingForAnswer?: "Waiting for you"
        default: "Creating…"
        }
    }

    /// The running stage in words, with the job's real percent when it has one.
    static func createStatus(_ create: CreateHost, progress: [UUID: JobProgress]) -> String {
        guard let flow = create.flow else { return "" }
        switch flow.phase {
        case .running(.input):
            return create.request?.input == .speak ? "Recording…" : "Bringing it in…"
        case .running(.transcribe):
            guard let id = flow.itemID, let job = progress[id] else { return "Waiting to start" }
            return Formatting.progress(job)
        case .running(.operation): return "Writing with the model…"
        case .running(.output): return "Making the voice message…"
        case .waitingForAnswer: return "A clinical step is waiting for your answer. Nothing has been sent."
        case .finished: return "Tap to see what was made."
        case .failed(_, let message): return message
        case .cancelled: return "Stopped. What was made stays in your Library."
        case .idle: return ""
        }
    }

    // MARK: - Dictate

    /// Dictate as a shortcut (M2): the Action Button, Back Tap and this tile start the same dictation.
    private var dictateTile: some View {
        Button {
            environment.dictation.start()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(Tokens.Color.accent)
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictate")
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    // Copy correction (handoff): "press", not "hold" (no Action Button key-up for third-party apps).
                    // Text-safe green (5.3:1; `success` is for fills and icons only, UX audit F12).
                    Text(environment.dictation.polishAfter ? "Clean text on copy" : "Action Button or tap")
                        .chirpFont(12)
                        .foregroundStyle(
                            environment.dictation.polishAfter ? Tokens.Color.privacyBadgeInk : Tokens.Color.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.tile))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            "Starts dictating. Press the Action Button, or tap to go hands-free. The text is copied when you stop.")
    }

    // MARK: - Tiles

    private func tile(title: String, subtitle: String, systemImage: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(AppColor.tintFill)
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Tokens.Color.accentInk)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(subtitle)
                        .chirpFont(12)
                        .foregroundStyle(Tokens.Color.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.tile))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Record Meeting

    /// M3: starts a meeting (the Meeting screen covers the tabs), or returns to one that is recording behind
    /// "Hide recording".
    private var recordMeetingRow: some View {
        let meeting = environment.meeting
        let isRunning = !meeting.state.isFinished
        return Button {
            if isRunning {
                meeting.isScreenHidden = false
            } else {
                meeting.dismiss()
                meeting.start()
            }
        } label: {
            HStack(spacing: 13) {
                RosetteMark(halo: meeting.state == .recording)
                    .frame(width: 40, height: 47)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRunning ? "Meeting in progress" : "Record Meeting")
                        .chirpFont(16, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(
                        isRunning
                            ? "Recording · \(Formatting.clock(ms: Int(meeting.recordedSeconds * 1000)))"
                            : "Microphone, transcribed on device"
                    )
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                }
                Spacer(minLength: 8)
                Text(isRunning ? "Return" : "Start")
                    .chirpFont(14, .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(Tokens.Color.accentFill))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(CardBackground(radius: Tokens.Radius.tile))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            isRunning ? "Returns to the meeting that is recording." : "Starts recording a meeting on this iPhone.")
    }

    // MARK: - Recent

    private var recentHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel("Recent", size: 12.5)
            Spacer()
            Button {
                openTab(.library)
            } label: {
                Text("See all")
                    .chirpFont(13.5, .semibold)
                    .foregroundStyle(AppColor.accentText)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)  // the hit area (UX audit F11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Library")
        }
    }

    @ViewBuilder private var recentList: some View {
        let recent = environment.capture.recent
        if recent.isEmpty {
            if environment.isLaunched {
                EmptyStateView(
                    title: "Nothing here yet",
                    message: "Tap Create to speak, type, paste a link or pick a file. What you make shows here."
                )
                .background(CardBackground(radius: Tokens.Radius.s))
            }
        } else {
            VStack(spacing: 9) {
                ForEach(recent) { item in
                    LibraryItemRow(
                        item: item,
                        progress: environment.jobCenter.progress[item.id],
                        compact: true,
                        onOpen: { path.append(item.id) },
                        onRetry: { environment.retry(item.id) }
                    )
                }
            }
        }
    }
}

/// "Download the speech model to transcribe", with a button that opens Settings. M7: it names the engine the
/// Transcripts route uses; for an engine other than Parakeet it says where to download it or how to switch back.
struct ModelMissingBanner: View {
    let engineName: String
    let status: ModelAssetStatus
    let isParakeet: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppColor.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isParakeet ? "Download the speech model to transcribe" : "Download \(engineName) to transcribe")
                    .chirpFont(14.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .chirpFont(12)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Spacer(minLength: 8)
            // CapsuleButtonLabel already grows its own hit area to 44pt (F7); no outer frame needed.
            Button(action: openSettings) {
                CapsuleButtonLabel(title: "Settings", kind: .filled)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CardBackground(radius: Tokens.Radius.s, fill: Tokens.Color.surface, stroke: AppColor.tintStroke))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch status {
        case .downloading(let fraction):
            return "Downloading · \(Formatting.percent(fraction))%"
        case .failed(let message):
            if isParakeet { return "The last download failed. Try again in Settings." }
            return (message.components(separatedBy: " Details: ").first ?? message)
                + " Or switch Transcripts to Parakeet in Settings → Speech engines."
        case .notDownloaded, .ready:
            if isParakeet { return "Parakeet runs on this iPhone after a one-time download." }
            return "Transcripts uses \(engineName). Download it in Settings → Speech engines, or switch Transcripts "
                + "to Parakeet."
        }
    }
}
