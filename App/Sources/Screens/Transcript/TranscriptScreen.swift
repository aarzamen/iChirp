import ChirpCore
import ChirpExport
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One transcript (canvas `Transcript.dc.html`): header with star and rename, Transcript / Ask tabs with a Notes button
/// and the privacy class, player bar, speaker paragraphs with tappable timestamps, and Copy / Share / Listen /
/// Transform (M4).
///
/// Polish (UX audit T): 44 pt targets for the star, timestamps and More; the tabs never break mid-word (the privacy
/// control moves to its own row when they do not fit); the privacy badge names the class the routers really use,
/// and which document raised it, when it is stricter than the stored mark (F51); Share lists PDF, Word, Text,
/// Voice message and then "More formats"; More → Delete… asks like the Library.
///
/// Plan 024 Task 9: the title, More menu, status card, reload and action bar are the Document screen's too
/// (`ItemScreenParts`); the view models are made once per screen (`OnceBox`, R6a-5); the playhead is followed by a
/// small watcher, so playback re-renders the screen once per paragraph, not ten times a second (R6a-10).
///
/// Plan 025 Part A: the lines are `TranscriptViewModel.lines` (the `.heard` view with the person's corrections), each
/// with a stable `id` (Jev's tags and scroll targets key by it). A corrected passage has a dotted underline and its
/// line says "Corrected"; a line's long-press offers Correct…, Show Original and Listen from Here (also as VoiceOver
/// actions); More → Corrections (N)… lists them all. A revert is immediate, with Undo for six seconds.
struct TranscriptScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    /// The screen's view models, made on the first render and kept (R6a-5).
    private struct Models {
        let transcript: TranscriptViewModel
        let player: AudioPlayerModel
        let ask: AskSessionViewModel
    }

    @State private var box = OnceBox<Models>()
    @State private var hasLoaded = false
    @State private var isShowingNotes = false  // M3
    @State private var shareItem: ShareItem?
    @State private var actionError: String?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var copied = false
    /// M4: the Ask tab and the Transform sheet.
    @State private var selectedTab: TranscriptTab = .transcript
    @State private var isTransforming = false
    /// M6a: the Jev decision on screen, its tags (this session only) and a template it suggested for Transform.
    @State private var decisionRun: DecisionRunViewModel?
    @State private var paragraphTags: [Int: String] = [:]
    @State private var suggestedTemplateKey: String?
    @State private var opensTransformAfterDecision = false
    /// M6: Extract fields (Needle 3 or the STUB), a draft card for review.
    @State private var isExtractingFields = false
    /// Plan 022: Share → Voice message.
    @State private var voiceMessage: VoiceMessageJob?
    /// F51: the class the privacy rules use, and why when it is stricter than the stored mark — the same
    /// `EffectivePrivacyExplanation` the document screens pass to `PrivacyClassControl`, so the badge and the
    /// routing never disagree unexplained. Bumped after a Transform so a new document's class is seen.
    @State private var privacy: EffectivePrivacyExplanation?
    @State private var documentsRevision = 0
    /// F53: More → Delete… is asking.
    @State private var isConfirmingDelete = false
    /// The paragraph the media playhead is in (set by `PlayheadWatcher` only when it changes).
    @State private var currentParagraph: Int?
    /// Plan 025: the line being corrected, the line whose original is shown, the Corrections sheet, and the Undo
    /// offered after a revert.
    @State private var correctingLine: TranscriptTextLine?
    @State private var originalLine: LineID?
    @State private var isShowingCorrections = false
    /// Undo for a revert whose sheet closed (Show Original with nothing left); sheets show their own (fix round 1).
    @State private var undo = CorrectionUndoController()

    /// A line id the Original sheet is open for (the sheet resolves the line itself, fix round 1, I2).
    struct LineID: Identifiable, Equatable {
        let id: Int
    }

    enum TranscriptTab { case transcript, ask }

    private var models: Models {
        box.get {
            let voice = environment.voicePlayer
            return Models(
                transcript: environment.makeTranscriptViewModel(id: id),
                player: AudioPlayerModel(session: environment.audioSession, willPlay: { voice.pause() }),
                ask: AskSessionViewModel(service: environment.deliverables, transcriptionID: id))
        }
    }

    private var model: TranscriptViewModel { models.transcript }
    private var player: AudioPlayerModel { models.player }
    private var ask: AskSessionViewModel { models.ask }

    var body: some View {
        // Read here so the Transform sheet (built in a closure) sees Jev's suggestion when it opens (M6a).
        let suggestedTemplate = suggestedTemplateKey
        VStack(spacing: 0) {
            tabs
            content
        }
        // Plan 020: the now-playing bar and the voice confirmation (the Transform sheet shows its own).
        .voiceReading(environment.voicePlayer, confirmationEnabled: !isTransforming && voiceMessage == nil) { source in
            switch source {
            case .transcript(let readID): readID == id
            case .askAnswer: true
            default: false
            }
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { titleHeader }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            if JevMenuPolicy.isVisible(
                jevEnabled: environment.jevSettingsModel.isMenuVisible, status: model.transcription?.status),
                let item = model.transcription
            {
                ToolbarItem(placement: .topBarTrailing) {
                    JevMenu(privacyClass: privacy?.effective ?? item.privacyClass) { recipe in  // review R6b-10
                        decisionRun = DecisionRunViewModel(
                            recipe: recipe, transcriptionID: id, service: environment.decisions)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.transcription?.status == .completed, selectedTab == .transcript {
                VStack(spacing: 0) {
                    CorrectionUndoBar(controller: undo, model: model)
                    bottomBar
                }
            }
        }
        .background {
            // A job started, moved on or ended for this row, or its stored status changed (a dictation's Retry
            // reports no job progress, R6a-3): re-read it, so the text appears when it is ready.
            ItemReloadWatcher(id: id) {
                Task {
                    await model.load()
                    player.load(model.mediaURL)
                }
            }
        }
        .background {
            PlayheadWatcher(player: player, paragraphs: model.paragraphs, current: $currentParagraph)
        }
        .task {
            await model.load()
            hasLoaded = true
            player.load(model.mediaURL)
        }
        .task(id: privacyKey) { await refreshPrivacy() }
        .onDisappear { player.stop() }
        .sheet(isPresented: $isShowingNotes, onDismiss: { Task { await model.load() } }) {
            TranscriptNotesSheet(id: id, store: environment.store)  // M3: notes and speaker names
        }
        .sheet(
            isPresented: $isTransforming,
            onDismiss: {
                suggestedTemplateKey = nil
                documentsRevision += 1  // a new document may be stricter than the transcript (F51)
                Task { await environment.deliverableLibrary.load() }
            }
        ) {
            if let item = model.transcription {
                TransformSheet(
                    transcriptionID: id, transcriptTitle: item.displayTitle, privacyClass: item.privacyClass,
                    environment: environment, suggestedTemplateKey: suggestedTemplate)
            }
        }
        .sheet(
            item: $decisionRun,
            onDismiss: {
                documentsRevision += 1
                if opensTransformAfterDecision {
                    opensTransformAfterDecision = false
                    isTransforming = true
                }
            }
        ) { run in
            DecisionResultSheet(
                run: run, host: environment.jevSettingsModel.host,
                markClinical: {
                    try await environment.deliverables.setPrivacyClass(.clinical, transcriptionID: id)
                    await model.load()
                },
                useTemplate: { key in
                    suggestedTemplateKey = key
                    opensTransformAfterDecision = true
                },
                showTags: { paragraphTags = $0 })
        }
        .sheet(isPresented: $isExtractingFields) {
            if let item = model.transcription {
                ExtractFieldsSheet(
                    transcriptionID: id, transcriptTitle: item.displayTitle, environment: environment,
                    onSeek: { ms in seek(toMs: ms) }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $voiceMessage) { job in VoiceMessageSheet(job: job, environment: environment) }
        .sheet(item: $correctingLine) { line in
            CorrectPassageSheet(
                line: line, speakerLabel: line.speakerLabel, player: player,
                save: { text in try await model.correct(line: line.id, text: text) })
        }
        .sheet(item: $originalLine) { line in
            PassageOriginalSheet(
                model: model, lineID: line.id, player: player, handOff: { offer in undo.adopt(offer) })
        }
        .sheet(isPresented: $isShowingCorrections) {
            CorrectionsSheet(model: model)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .itemDeleteConfirmation(
            isPresented: $isConfirmingDelete, item: model.transcription, environment: environment,
            onDeleted: { dismiss() }, onError: { actionError = $0 }
        )
        .alert(model.transcription.map(ItemNoun.renameTitle) ?? "Rename", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.transcription.map(ItemNoun.renameMessage) ?? "")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Header

    @ViewBuilder private var titleHeader: some View {
        if let item = model.transcription {
            ItemTitleHeader(
                item: item, meta: Formatting.transcriptMeta(for: item),
                onFavorite: { Task { await toggleFavorite() } }, onRename: startRename)
        }
    }

    private var moreMenu: some View {
        ItemMoreMenu(
            item: model.transcription, onRename: startRename, onFavorite: { Task { await toggleFavorite() } },
            onCopy: copyText, onExtractFields: { isExtractingFields = true },
            onDelete: { isConfirmingDelete = true },
            corrections: TranscriptCorrectionsCopy.menuTitle(
                applied: model.corrections.count, detached: model.detachedCorrections.count
            ).map { title in (title, { isShowingCorrections = true }) })
    }

    // MARK: - Tabs (Transcript and Ask), the Notes button (M3) and the privacy class (M4)

    /// One row when it fits: Transcript, Ask, Notes, then the privacy control. Otherwise (large text) the privacy
    /// control and Notes take a row of their own (stacking if they must) above the two tabs, so nothing is clipped at
    /// the screen's edge; the tabs scroll sideways rather than break a word (F48). Labels never wrap.
    private var tabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    tabItems
                    notesButton
                    Spacer(minLength: 0)
                    privacyControl
                }
                VStack(alignment: .leading, spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Spacing.s) {
                            privacyControl
                            Spacer(minLength: 0)
                            notesButton
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            privacyControl
                            notesButton
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) { tabItems }
                    }
                }
            }
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Tokens.Color.border).frame(height: 1)
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var tabItems: some View {
        tabButton("Transcript", selected: selectedTab == .transcript) { selectedTab = .transcript }
        tabButton("Ask", selected: selectedTab == .ask) { selectedTab = .ask }
    }

    /// F52: Notes opens a sheet, so it looks like a button, not a third tab; R7-17: a quiet capsule, so the selected
    /// tab's coral underline stays the loudest thing in the row.
    private var notesButton: some View {
        Button {
            isShowingNotes = true
        } label: {
            // Title only, so the tabs and the privacy control still share one row at the default size.
            Text("Notes")
                .chirpFont(13.5, .semibold)
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Tokens.Spacing.s)
                .frame(minHeight: Tokens.Metric.compactButtonHeight)
                .background(Capsule().fill(Tokens.Color.quietFill))
                .frame(minWidth: Tokens.Metric.minTapTarget, minHeight: Tokens.Metric.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notes")
        .accessibilityHint("Opens your notes and the speaker names")
    }

    @ViewBuilder private var privacyControl: some View {
        if let item = model.transcription {
            // F51: `effective:` names which document (e.g. "Clinical (it has a SOAP note)") raises the badge
            // above the stored mark, the same control the document screens use, so it and the badge never
            // disagree with what Listen, Ask and Transform actually do.
            PrivacyClassControl(current: item.privacyClass, effective: privacy) { newClass in
                // Through the service, so the transcript's documents are raised with it (never lowered).
                try await environment.deliverables.setPrivacyClass(newClass, transcriptionID: id)
                await model.load()
            }
        }
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .chirpFont(14.5, selected ? .bold : .semibold)
                .foregroundStyle(selected ? Tokens.Color.ink : Tokens.Color.secondary)
                .lineLimit(1)
                .fixedSize()  // F48: never "Tra/ns/cri/pt"
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(Tokens.Color.accent).frame(height: 2.5)
                    }
                }
                .frame(minWidth: 44)  // the underline stays the text's width; the target is at least 44 pt
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let item = model.transcription {
            switch item.status {
            case .completed:
                completedContent(item)
            case .processing:
                ItemStatusPanel(
                    id: id,
                    content: .processing(
                        message: "The text appears here when Parakeet finishes. You can leave this screen meanwhile."))
            case .failed, .interrupted, .cancelled:
                ItemStatusPanel(
                    id: id,
                    content: .problem(
                        title: item.status == .cancelled ? "Cancelled" : "Couldn’t transcribe",
                        message: Formatting.statusLine(for: item, progress: nil) ?? "",
                        isError: item.status != .cancelled, canRetry: true))
            }
        } else if let error = model.loadError {
            ItemStatusPanel(
                id: id,
                content: .problem(
                    title: "Couldn’t open this transcript", message: error, isError: true, canRetry: false))
        } else if hasLoaded {
            ItemStatusPanel(
                id: id,
                content: .problem(
                    title: "This transcript is gone", message: "It may have been deleted.", isError: false,
                    canRetry: false))
        } else {
            Spacer()
        }
    }

    private func completedContent(_ item: Transcription) -> some View {
        let paragraphs = model.paragraphs
        let hasTimings = model.hasWordTimings
        let speakerOrder = SpeakerPalette.order(paragraphs.map(\.speakerId))
        let current = (player.isAvailable && hasTimings) ? currentParagraph : nil
        return VStack(spacing: 0) {
            if player.isAvailable {
                PlayerBar(player: player)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }
            if selectedTab == .ask {
                AskView(transcription: item, session: ask, environment: environment) { ms in seek(toMs: ms) }
            } else {
                transcriptText(hasTimings: hasTimings, speakerOrder: speakerOrder, current: current)
            }
        }
    }

    /// The lines (`model.lines`, parallel to `model.paragraphs`), each with its stable id: the scroll target, and the
    /// key of Jev's tags (a correction that covers a whole paragraph leaves its id out, so positions and ids differ).
    private func transcriptText(hasTimings: Bool, speakerOrder: [String: Int], current: Int?) -> some View {
        let lines = model.lines
        let tokens = model.heard?.tokens ?? []
        // Each line is a scroll target by its id (`.id(line.id)`); plan 025 Part B's Find scrolls to a match with the
        // reader's proxy.
        return ScrollViewReader { _ in
            ScrollView {
                // Plan 023 (UX audit F43): the documents made from this transcript, above its text; plan 025: those made
                // before the latest correction say so.
                MadeFromThisSection(
                    sourceID: id, padding: EdgeInsets(top: 14, leading: 24, bottom: 0, trailing: 24),
                    correctionsChangedAt: MadeBeforeCorrections.changedAt(of: model))
                if model.transcription?.isPartialAudio == true {
                    PartialAudioNotice()
                        .padding(.horizontal, Tokens.Spacing.xl)
                        .padding(.top, Tokens.Spacing.s)
                }
                if lines.isEmpty {
                    EmptyStateView(title: "No speech found", message: "Parakeet didn’t hear any words in this file.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { position, line in
                            lineView(
                                line, tokens: tokens,
                                speakerIndex: line.speakerId.flatMap { speakerOrder[$0] },
                                showsTiming: hasTimings,
                                isCurrent: position == current,
                                jevTag: paragraphTags[line.id]
                            )
                            .id(line.id)
                            .contextMenu { lineMenu(line, position: position) }
                            // F55: the long-press items, reachable from the VoiceOver actions rotor too.
                            // The long-press items, as VoiceOver actions, offered when the menu offers them (F55).
                            .accessibilityActions {
                                if model.canCorrect {
                                    Button("Correct") { startCorrecting(line) }
                                }
                                if !model.corrections(inLine: line.id).isEmpty {
                                    Button("Show Original") { showOriginal(line) }
                                }
                                Button("Listen from Here") { listen(from: position) }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    /// A line's long-press: Correct… (a finished, timed transcript), Show Original (a corrected line), Listen from Here.
    @ViewBuilder private func lineMenu(_ line: TranscriptTextLine, position: Int) -> some View {
        if model.canCorrect {
            Button {
                startCorrecting(line)
            } label: {
                Label("Correct…", systemImage: "pencil")
            }
        }
        if !model.corrections(inLine: line.id).isEmpty {
            Button {
                showOriginal(line)
            } label: {
                Label("Show Original", systemImage: "text.badge.checkmark")
            }
        }
        // Plan 020: read aloud from this paragraph onward.
        Button {
            listen(from: position)
        } label: {
            Label("Listen from Here", systemImage: "speaker.wave.2")
        }
    }

    private func lineView(
        _ line: TranscriptTextLine, tokens: [TranscriptToken], speakerIndex: Int?, showsTiming: Bool, isCurrent: Bool,
        jevTag: String? = nil
    ) -> some View {
        let isCorrected = TranscriptLineText.correctionCount(in: line, tokens: tokens) > 0
        return VStack(alignment: .leading, spacing: 6) {
            if let jevTag {
                ParagraphTagChip(title: jevTag)  // M6a: this session only
            }
            if showsTiming {
                // The 44 pt timestamp target overlaps the paragraph spacing instead of adding to it.
                // Plan 025: "Corrected" sits beside the speaker and time when it fits, and on its own row at large text
                // sizes (never breaking "Speaker 1" or itself mid-word).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        speakerAndTime(line, speakerIndex: speakerIndex, isCurrent: isCurrent)
                        if isCorrected { correctedLabel }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 7) {
                            speakerAndTime(line, speakerIndex: speakerIndex, isCurrent: isCurrent)
                        }
                        if isCorrected { correctedLabel }
                    }
                }
                .padding(.vertical, -8)
            }
            Text(TranscriptLineText.attributed(line, tokens: tokens))
                .chirpFont(16)
                .lineSpacing(6)
                .foregroundStyle(Tokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityValue(isCorrected ? "Corrected" : "")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.cover, style: .continuous)
                .fill(isCurrent ? AppColor.tintFill : Color.clear)
        )
        .padding(.horizontal, -10)
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }

    @ViewBuilder private func speakerAndTime(_ line: TranscriptTextLine, speakerIndex: Int?, isCurrent: Bool)
        -> some View
    {
        let startMs = line.startMs ?? 0
        if let speakerIndex {
            SpeakerDot(label: model.speakerLabel(for: line.speakerId), speakerIndex: speakerIndex)
        }
        Button {
            seek(toMs: startMs)
        } label: {
            Text(Formatting.clock(ms: startMs))
                .chirpFont(11.5)
                .monospacedDigit()
                // Text-safe ink on the current paragraph's tint fill (F8): `accentText` alone is 4.39:1 there.
                .foregroundStyle(
                    player.isAvailable
                        ? (isCurrent ? AppColor.accentTextOnTint : AppColor.accentText)
                        : Tokens.Color.secondary
                )
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)  // F49: 44 pt to tap
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!player.isAvailable)
        .accessibilityLabel("Play from \(Formatting.clock(ms: startMs))")
    }

    /// Plan 025: the line carries the person's corrections (Show Original brings back the words as heard). VoiceOver
    /// hears it as the line's value instead.
    private var correctedLabel: some View {
        Text("Corrected")
            .chirpFont(11.5)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ItemActionBar(
            copied: copied, onCopy: copyText,
            // Plan 020: reads from the paragraph at the playhead (or the start); the media player pauses first.
            listen: ListenBarButton(
                source: .transcript(id: id), privacyClass: model.transcription?.privacyClass ?? .clinical,
                text: { listenText(from: listenStartIndex) }, willListen: { player.pause() }),
            onTransform: { isTransforming = true }
        ) {
            // F54: PDF, Word, Text — the same order as the document screens' Share menu; the rest under one menu.
            ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) { shareDocument(format) }
            }
            Button(ExportFormat.txt.displayName) { share(.txt) }
            Button {
                voiceMessage = model.transcription.flatMap { VoiceMessageJob.item($0, text: model.plainText) }
            } label: {
                Label("Voice message…", systemImage: "waveform.badge.plus")
            }
            Menu("More formats") {
                ForEach(Self.moreShareFormats, id: \.self) { format in
                    Button(Self.shareTitle(format)) { share(format) }
                }
            }
        }
    }

    // MARK: - Actions

    /// Plan 020: "Listen from Here" on a paragraph.
    private func listen(from index: Int) {
        guard let item = model.transcription else { return }
        player.pause()
        let text = SpeakableText.prepare(listenText(from: index))
        let voice = environment.voicePlayer
        Task { await voice.speak(text: text, privacyClass: item.privacyClass, source: .transcript(id: id)) }
    }

    /// The transcript's paragraphs from `index` on, one paragraph each (a short pause between them).
    private func listenText(from index: Int) -> String {
        let paragraphs = model.paragraphs
        guard paragraphs.indices.contains(index) else { return model.plainText }
        return paragraphs[index...].map(\.text).joined(separator: "\n\n")
    }

    /// Where Listen starts: the paragraph at the media playhead once the media has played, else the first.
    private var listenStartIndex: Int {
        guard player.currentTime > 0, model.hasWordTimings else { return 0 }
        return TranscriptTiming.currentParagraphIndex(in: model.paragraphs, atMs: Int(player.currentTime * 1000)) ?? 0
    }

    // MARK: - Corrections (plan 025)

    private func startCorrecting(_ line: TranscriptTextLine) {
        guard model.canCorrect else { return }
        correctingLine = line
    }

    private func showOriginal(_ line: TranscriptTextLine) {
        guard !model.corrections(inLine: line.id).isEmpty else { return }
        originalLine = LineID(id: line.id)
    }

    private func seek(toMs ms: Int) {
        player.seek(to: TimeInterval(ms) / 1000)
        if !player.isPlaying { player.play() }
    }

    private func copyText() {
        // Local-only, so transcript text never syncs over Universal Clipboard; announced to VoiceOver (F55).
        ItemCopy.copy(model.plainText)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Plan 022 Step 6: a PDF or Word copy for the share sheet (rendered off the main actor).
    private func shareDocument(_ format: DocumentExportFormat) {
        Task {
            do {
                shareItem = ShareItem(url: try await model.exportDocument(format))
            } catch {
                actionError = Formatting.message(for: error)
            }
        }
    }

    /// TXT, Markdown, SRT, VTT or JSON for the share sheet (written off the main actor, review R4-20).
    private func share(_ format: ExportFormat) {
        Task {
            do {
                shareItem = ShareItem(url: try await model.exportFile(format))
            } catch {
                actionError = Formatting.message(for: error)
            }
        }
    }

    private func startRename() {
        renameText = model.transcription?.titleOverride ?? model.transcription?.displayTitle ?? ""
        isRenaming = true
    }

    private func rename() async {
        do {
            try await model.rename(renameText)
        } catch {
            actionError = Formatting.message(for: error)
        }
    }

    /// Re-read when the stored class changes or a Transform or Jev sheet closes (F51).
    private var privacyKey: String {
        "\(model.transcription?.privacyClass.rawValue ?? "-")#\(documentsRevision)"
    }

    private func refreshPrivacy() async {
        guard model.transcription != nil else {
            privacy = nil
            return
        }
        // Unreadable documents: say nothing extra rather than guess (the routers themselves fail safe to clinical).
        privacy = try? await EffectivePrivacyExplanation.current(
            transcriptionID: id, transcripts: environment.store, deliverables: environment.deliverableStore)
    }

    /// F54: the formats under Share → More formats, in this order.
    static let moreShareFormats: [ExportFormat] = [.markdown, .srt, .vtt, .json]

    /// F54: plain words for the specialist formats ("Subtitles (SRT)", "Data (JSON)").
    static func shareTitle(_ format: ExportFormat) -> String {
        switch format {
        case .txt: "Text"
        case .markdown: "Markdown"
        case .srt: "Subtitles (SRT)"
        case .vtt: "Subtitles (VTT)"
        case .json: "Data (JSON)"
        }
    }

    private func toggleFavorite() async {
        do {
            try await model.toggleFavorite()
        } catch {
            actionError = Formatting.message(for: error)
        }
    }
}

/// Follows the media playhead and writes the paragraph it is in to `current` only when that changes (R6a-10): the
/// player ticks ten times a second, and only this invisible view reads its time, so the Transcript screen re-renders
/// once per paragraph instead of on every tick.
struct PlayheadWatcher: View {
    let player: AudioPlayerModel
    let paragraphs: [TranscriptParagraph]
    @Binding var current: Int?

    var body: some View {
        let index =
            player.isAvailable
            ? TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: Int(player.currentTime * 1000)) : nil
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: index, initial: true) { _, new in
                if current != new { current = new }
            }
    }
}

/// Which paragraph the playhead is in.
enum TranscriptTiming {
    /// The last paragraph that starts at or before `ms`, or nil before the first one starts.
    static func currentParagraphIndex(in paragraphs: [TranscriptParagraph], atMs ms: Int) -> Int? {
        var current: Int?
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.startMs <= ms {
                current = index
            } else {
                break
            }
        }
        return current
    }
}

extension ExportError: ExportErrorDescribing {
    var readableMessage: String {
        switch self {
        case .noTimestamps:
            "SRT and VTT need word timings, and this transcript has none. Share it as Text or Markdown instead."
        }
    }
}
