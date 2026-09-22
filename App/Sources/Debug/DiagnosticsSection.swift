#if DEBUG
import ChirpCore
import ChirpUI
import SwiftUI

/// Settings → Diagnostics (DEBUG builds only): where the models and database live, the bundled-sample smoke run,
/// and a manual "mark stale jobs interrupted".
struct DiagnosticsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var staleResult: String?

    var body: some View {
        SettingsGroup(title: "Diagnostics") {
            pathRow("Models folder", environment.speechEngine.modelsRoot.path)
            pathRow("Database", environment.paths.databaseURL.path)
            smokeRow
            staleRow
        }
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .chirpFont(15.5)
                .foregroundStyle(Tokens.Color.ink)
            Text(path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Tokens.Color.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var smokeRow: some View {
        let smoke = environment.smoke
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                smoke.start(environment: environment, reason: .diagnostics)
            } label: {
                HStack {
                    Text("Transcribe bundled sample")
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(smoke.isRunning ? Tokens.Color.mutedText : AppColor.accentText)
                    Spacer()
                    Image(systemName: "play.circle")
                        .foregroundStyle(smoke.isRunning ? Tokens.Color.mutedText : AppColor.accentText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(smoke.isRunning)
            Text(smokeCaption(smoke.state))
                .chirpFont(12.5)
                .monospacedDigit()
                .foregroundStyle(smokeCaptionColor(smoke.state))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var staleRow: some View {
        let jobRunning = !environment.jobCenter.progress.isEmpty || environment.smoke.isRunning
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await markStale() }
            } label: {
                HStack {
                    Text("Mark stale jobs interrupted")
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(jobRunning ? Tokens.Color.mutedText : AppColor.accentText)
                    Spacer()
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(jobRunning)
            Text(
                jobRunning
                    ? "Unavailable while a transcription is running"
                    : (staleResult ?? "Moves rows stuck in “processing” to “interrupted” so they can be retried.")
            )
            .chirpFont(12.5)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func markStale() async {
        // Re-checked here: only safe while no job runs in this process.
        guard environment.jobCenter.progress.isEmpty, !environment.smoke.isRunning else { return }
        do {
            let count = try await environment.store.markStaleProcessingAsInterrupted()
            staleResult = count == 1 ? "Marked 1 row interrupted." : "Marked \(count) rows interrupted."
        } catch {
            staleResult = "Failed: \(Formatting.message(for: error))"
        }
    }

    private func smokeCaption(_ state: SmokeTestRunner.State) -> String {
        switch state {
        case .idle:
            return "Downloads the models if needed, then writes Documents/smoke-result.json."
        case .running(let step):
            return "\(step)…"
        case .finished(let result):
            if result.status == "completed" {
                return "Completed · \(result.wordCount) words · \(result.speakerCount) speakers · "
                    + "\(result.elapsedMs) ms (+\(result.modelLoadMs) ms load) · peak \(result.peakMemoryMB) MB\n"
                    + result.text
            }
            return "Failed: \(result.error ?? "unknown error")"
        }
    }

    private func smokeCaptionColor(_ state: SmokeTestRunner.State) -> Color {
        if case .finished(let result) = state, result.status != "completed" { return AppColor.error }
        return Tokens.Color.secondary
    }
}
#endif
