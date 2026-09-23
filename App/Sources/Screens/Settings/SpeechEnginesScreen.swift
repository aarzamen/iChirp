import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Speech → Speech engines (M7): the row that opens the engine picker.
struct SpeechEnginesSettingsLink: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let engines = environment.speechEngines
        NavigationLink {
            SpeechEnginesScreen()
        } label: {
            SettingsRow(title: "Speech engines", caption: Self.caption(engines)) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    static func caption(_ engines: SpeechEnginesViewModel) -> String {
        let live = engines.row(for: .live)?.capabilities.displayName ?? "Parakeet"
        let final = engines.row(for: .final)?.capabilities.displayName ?? "Parakeet"
        return live == final ? "\(final) for live text and transcripts" : "Live: \(live) · Transcripts: \(final)"
    }
}

/// Settings → Speech engines (M7, plan 016): which engine shows live text, which one writes the transcript you keep,
/// and every engine this build knows, with its size, what it can do and its model. All of them run on this iPhone.
struct SpeechEnginesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var deleting: SpeechEnginesViewModel.Row?

    var body: some View {
        let engines = environment.speechEngines
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Speech engines")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "One engine shows live text while you speak; another can write the transcript you keep. Every "
                        + "engine here runs on this iPhone."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

                SettingsGroup(
                    title: "Use",
                    footer: "A change applies to the next recording or file, never to one already running. It can’t "
                        + "change during a meeting. Only downloaded engines can be picked."
                ) {
                    routeRow(.live, title: "Live text", caption: "Dictation preview and meeting live text")
                    routeRow(.final, title: "Transcripts", caption: "Files, dictations and meetings you keep")
                }

                SettingsGroup(title: "Engines") {
                    ForEach(engines.rows) { row in
                        SpeechEngineRow(
                            row: row,
                            onDownload: {
                                environment.downloadSpeechEngine(row.id, title: row.capabilities.displayName)
                            },
                            onDelete: { deleting = row })
                    }
                }

            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .task { await engines.refresh() }
        .alert(
            "Speech engines",
            isPresented: Binding(get: { engines.lastError != nil }, set: { if !$0 { engines.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engines.lastError ?? "")
        }
        .confirmationDialog(
            "Delete the \(deleting?.capabilities.displayName ?? "") model?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                if let key = deleting?.id {
                    Task { await engines.delete(key) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(
                deleting?.capabilities.modelLifecycle.isSystemManaged == true
                    ? "Your transcripts stay. iOS may remove the speech model when no app needs it."
                    : "Your transcripts stay. Parakeet needs to download the model again before it can use it.")
        }
    }

    private func routeRow(_ route: SpeechRoute, title: String, caption: String) -> some View {
        let engines = environment.speechEngines
        let current = engines.row(for: route)
        return SettingsRow(title: title, caption: caption) {
            Menu {
                ForEach(engines.choices(for: route)) { row in
                    Button {
                        engines.select(row.id, for: route)
                    } label: {
                        if row.id == current?.id {
                            Label(row.capabilities.displayName, systemImage: "checkmark")
                        } else {
                            Text(row.capabilities.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current?.capabilities.displayName ?? "Parakeet")
                        .chirpFont(15)
                        .foregroundStyle(AppColor.accentText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.accentText)
                }
            }
            .accessibilityLabel("\(title): \(current?.capabilities.displayName ?? "Parakeet")")
        }
    }
}

/// One engine build: name, provider, what it can do, its model state and the action that fits it.
private struct SpeechEngineRow: View {
    let row: SpeechEnginesViewModel.Row
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let capabilities = row.capabilities
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(capabilities.displayName)
                    .chirpFont(15.5)
                    .foregroundStyle(isUnavailable ? Tokens.Color.secondary : Tokens.Color.ink)
                Spacer(minLength: 8)
                Text(sizeText)
                    .chirpFont(13)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Text(capabilities.providerSummary + " · " + capabilities.runsOn)
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
            Text(capabilityText)
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 10) {
                Text(statusText)
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                action
            }
            if case .downloading(let fraction) = row.availability {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(Tokens.Color.accent)
                    .accessibilityLabel("\(capabilities.displayName) download")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var isUnavailable: Bool {
        if case .unavailable = row.availability { return true }
        return false
    }

    private var sizeText: String {
        let lifecycle = row.capabilities.modelLifecycle
        if lifecycle.isSystemManaged { return "Built into iOS" }
        return lifecycle.approximateDownloadBytes.map { Formatting.size(bytes: $0) } ?? ""
    }

    private var capabilityText: String {
        let capabilities = row.capabilities
        var parts: [String] = [capabilities.supportedLanguages.summary]
        if capabilities.providesWordTimestamps { parts.append("word timings") }
        if capabilities.supportsNativeLiveDictation {
            parts.append("streams live text")
        } else if capabilities.supportsTailPreview {
            parts.append("live preview")
        }
        if let memory = capabilities.modelLifecycle.approximateRuntimeMemoryBytes {
            parts.append("about \(Formatting.size(bytes: memory)) memory")
        }
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch row.availability {
        case .unavailable(let reason):
            return reason
        case .downloading(let fraction):
            return "Downloading \(Formatting.percent(fraction))%"
        case .ready:
            if row.capabilities.modelLifecycle.isSystemManaged { return "Ready · managed by iOS" }
            if case .ready(let bytes) = row.status { return "On device · \(Formatting.size(bytes: bytes))" }
            return "Ready"
        case .downloadable:
            if let failure = row.failureMessage {
                return "Download failed: " + (failure.components(separatedBy: " Details: ").first ?? failure)
            }
            return row.capabilities.modelLifecycle.isSystemManaged
                ? "Not downloaded · iOS downloads it" : "Not downloaded"
        }
    }

    private var statusColor: Color {
        if row.failureMessage != nil { return AppColor.error }
        return Tokens.Color.secondary
    }

    @ViewBuilder private var action: some View {
        switch row.availability {
        case .downloadable:
            Button(action: onDownload) {
                CapsuleButtonLabel(title: row.failureMessage == nil ? "Download" : "Try again", kind: .filled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(row.capabilities.displayName)")
        case .ready where row.capabilities.modelLifecycle.isUserDeletable:
            Button(action: onDelete) { CapsuleButtonLabel(title: "Delete", kind: .destructive) }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(row.capabilities.displayName)")
        default:
            EmptyView()
        }
    }
}
