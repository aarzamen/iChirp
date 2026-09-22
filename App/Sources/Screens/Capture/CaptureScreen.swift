import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// Tab 1 (canvas `Home.dc.html`): the header, Dictate card, Paste a link / Import audio tiles, Record Meeting, and
/// the three most recent transcriptions. Dictate (M2), Record Meeting (M3), Import audio and Recent are real; the rest
/// open "Not built yet" sheets.
struct CaptureScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let openTab: (AppTab) -> Void

    @State private var path: [UUID] = []
    @State private var placeholder: Placeholder?
    @State private var isImporting = false
    @State private var pickerError: String?
    /// M5: the Paste a link sheet.
    @State private var isPastingLink = false

    static let importTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if environment.isLaunched, !environment.isSpeechModelReady {
                        ModelMissingBanner(status: environment.speechSettings.speechStatus) {
                            openTab(.settings)
                        }
                    }
                    dictateCard
                    HStack(spacing: 14) {
                        tile(
                            title: "Paste a link", subtitle: "Podcast, YouTube, PDF", systemImage: "link",
                            action: { isPastingLink = true })
                        tile(
                            title: "Import audio", subtitle: "Voice Memos, Files",
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
        .ingestPreviewLaunch(environment: environment, isPastingLink: $isPastingLink, path: $path)
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
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

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            environment.importFiles(urls)
        case .failure(let error):
            pickerError = Formatting.message(for: error)
        }
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
            StatusChip.onDevice()
        }
        .frame(minHeight: 40)
    }

    // MARK: - Dictate

    private var dictateCard: some View {
        Button {
            environment.dictation.start()
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Tokens.Color.accent)
                        .shadow(color: Tokens.Color.accent.opacity(0.32), radius: 8, y: 6)
                    Image(systemName: "waveform")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Dictate")
                        .chirpTitleFont(23)
                        .foregroundStyle(Tokens.Color.ink)
                    // Copy correction (handoff): third-party apps get no Action Button key-up, so it is "press", not
                    // "hold". The chip is true only while "Polish after" is on.
                    Text("Press the Action Button, or tap to go hands-free.")
                        .chirpFont(13.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if environment.dictation.polishAfter {
                        StatusChip.cleanTextOnCopy()
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.xl, fill: AppColor.tintFill, stroke: AppColor.tintStroke))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.xl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Starts dictating. The text is copied when you stop.")
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
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
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
                    .background(Capsule().fill(Tokens.Color.accentInk))
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
            Button("See all") { openTab(.library) }
                .chirpFont(13.5, .semibold)
                .foregroundStyle(AppColor.accentText)
                .frame(minHeight: 32)
        }
    }

    @ViewBuilder private var recentList: some View {
        let recent = environment.capture.recent
        if recent.isEmpty {
            if environment.isLaunched {
                EmptyStateView(
                    title: "Nothing transcribed yet",
                    message: "Tap Import audio to transcribe a voice memo or any audio or video file."
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

/// "Download the speech model to transcribe", with a button that opens Settings.
struct ModelMissingBanner: View {
    let status: ModelAssetStatus
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppColor.accentText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download the speech model to transcribe")
                    .chirpFont(14.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .chirpFont(12)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Spacer(minLength: 8)
            Button(action: openSettings) {
                CapsuleButtonLabel(title: "Settings", kind: .filled)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CardBackground(radius: Tokens.Radius.s, fill: Tokens.Color.surface, stroke: AppColor.tintStroke))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch status {
        case .downloading(let fraction): "Downloading · \(Formatting.percent(fraction))%"
        case .failed: "The last download failed. Try again in Settings."
        case .notDownloaded, .ready: "Parakeet runs on this iPhone after a one-time download."
        }
    }
}
