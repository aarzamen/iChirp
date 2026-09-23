import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Speech engines → Benchmark (M7 Step 6, plan 016): runs the chosen engines one at a time over the
/// synthetic reference set (known words) and any files the owner adds, and shows word error rate, speed, load time and
/// peak memory. Results stay on this iPhone in one JSON file; Export shares them as CSV and JSON.
struct ASRBenchmarkScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var importing = false
    @State private var exportURLs: [URL] = []

    var body: some View {
        let model = environment.benchmark
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Benchmark")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Each engine runs on its own, one recording at a time. Keep Parakeet open while it runs; nothing "
                        + "leaves this iPhone."
                )
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

                SettingsGroup(title: "Engines", footer: "Only engines whose model is downloaded can run.") {
                    ForEach(model.engines) { engine in
                        engineRow(engine)
                    }
                }

                SettingsGroup(
                    title: "Recordings",
                    footer: "Your own files get speed and memory only (there is no known text to compare). Their "
                        + "words and names are not kept, and their copies are deleted when the run ends."
                ) {
                    SettingsRow(
                        title: "Reference set",
                        caption: "\(model.referenceItems.count) synthetic recordings with known words"
                    ) {
                        Toggle("Reference set", isOn: Bindable(model).includeReferenceSet)
                            .labelsHidden()
                            .tint(Tokens.Color.success)
                    }
                    ForEach(model.userItems) { item in
                        SettingsRow(title: item.title, caption: "Copied for this run only") {
                            Button {
                                model.removeUserItem(item.id)
                            } label: {
                                CapsuleButtonLabel(title: "Remove", kind: .destructive)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isRunning)
                        }
                    }
                    Button {
                        importing = true
                    } label: {
                        SettingsRow(title: "Add files…") {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppColor.accentText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                }

                runSection(model)

                if let run = model.latest {
                    resultsSection(run)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refresh()
            refreshExport()
        }
        .onChange(of: model.history.count) { refreshExport() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.addFiles(urls) }
        }
        .alert(
            "Benchmark",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    // MARK: - Rows

    private func engineRow(_ engine: ASRBenchmarkViewModel.EngineChoice) -> some View {
        let model = environment.benchmark
        return SettingsRow(title: engine.name, caption: engine.unavailableReason) {
            Toggle(
                engine.name,
                isOn: Binding(get: { model.selected.contains(engine.key) }, set: { _ in model.toggle(engine.key) })
            )
            .labelsHidden()
            .tint(Tokens.Color.success)
            .disabled(!engine.isReady || model.isRunning)
        }
    }

    private func runSection(_ model: ASRBenchmarkViewModel) -> some View {
        SettingsGroup(title: "Run") {
            if model.isRunning, let progress = model.progress {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progressText(progress))
                        .chirpFont(13)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(Tokens.Color.accent)
                    Button {
                        model.cancel()
                    } label: {
                        CapsuleButtonLabel(title: "Stop", kind: .destructive)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                Button {
                    model.run()
                } label: {
                    SettingsRow(title: "Run benchmark", caption: runCaption(model)) {
                        CapsuleButtonLabel(title: "Run", kind: .filled)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canRun)
                .opacity(model.canRun ? 1 : 0.5)
            }
        }
    }

    private func resultsSection(_ run: ASRBenchmarkRun) -> some View {
        SettingsGroup(
            title: "Latest results",
            footer: "WER: word errors per reference word (lower is better). Speed: seconds of audio per second of "
                + "work. Load: the model load after unloading it. Peak: the app's memory; Apple Speech runs "
                + "outside the app. \(run.device) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"
        ) {
            ForEach(run.summaries) { summary in
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.engineName)
                        .chirpFont(15.5)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(summaryText(summary))
                        .chirpFont(12.5)
                        .monospacedDigit()
                        .foregroundStyle(summary.failures > 0 ? AppColor.error : Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if !exportURLs.isEmpty {
                ShareLink(items: exportURLs) {
                    SettingsRow(title: "Export CSV and JSON", caption: "Every saved run") {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColor.accentText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Text

    private func progressText(_ progress: ASRBenchmarkProgress) -> String {
        let step = "\(min(progress.completed + 1, progress.total)) of \(progress.total)"
        guard !progress.engineName.isEmpty else { return "Preparing recordings…" }
        return "\(progress.engineName) · \(progress.itemTitle) · \(step)"
    }

    private func runCaption(_ model: ASRBenchmarkViewModel) -> String {
        let engines = model.engines.filter { $0.isReady && model.selected.contains($0.key) }.count
        let items = (model.includeReferenceSet ? model.referenceItems.count : 0) + model.userItems.count
        return "\(engines) engine\(engines == 1 ? "" : "s") × \(items) recording\(items == 1 ? "" : "s")"
    }

    private func summaryText(_ summary: ASRBenchmarkRun.EngineSummary) -> String {
        var parts: [String] = []
        if let wer = summary.wordErrorRate {
            parts.append(String(format: "WER %.1f%%", wer.rate * 100))
        }
        if let rtf = summary.realTimeFactor, rtf > 0 {
            parts.append(String(format: "%.0f× real time", 1 / rtf))
        }
        if let load = summary.loadMs {
            parts.append("load " + (load < 1_000 ? "\(load) ms" : String(format: "%.1f s", Double(load) / 1_000)))
        }
        if let peak = summary.peakMemoryBytes {
            parts.append("peak \(Formatting.size(bytes: Int64(peak)))")
        }
        if summary.failures > 0 {
            parts.append("\(summary.failures) failed")
        }
        return parts.isEmpty ? "No result" : parts.joined(separator: " · ")
    }

    private func refreshExport() {
        guard !environment.benchmark.history.isEmpty else {
            exportURLs = []
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "benchmark-export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        exportURLs = (try? environment.benchmark.exportFiles(to: folder)) ?? []
    }
}
