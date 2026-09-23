import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Models → "Small models on this iPhone" (M7, ADR-015): each llama.cpp model with its size, memory, window
/// and license, an on-device badge, and Download / Delete. A downloaded model becomes a choice for Transform and Ask
/// above; clinical items may use it without a confirmation because nothing leaves the phone.
struct OnDeviceModelsSection: View {
    @Environment(AppEnvironment.self) private var environment
    /// The model whose Download was tapped, while its size / memory question is open (review I3c).
    @State private var pendingDownload: PendingDownload?

    private struct PendingDownload: Identifiable {
        let option: LocalModelOption
        let notice: LocalModelDownloadNotice
        var id: String { option.id }
    }

    var body: some View {
        @Bindable var models = environment.languageModels
        SettingsGroup(
            title: "Small models on this iPhone",
            footer:
                "Downloaded only when you tap Download, then they run on this iPhone's GPU with nothing sent anywhere. "
                + "They work while Parakeet is on screen: keep it open until the text is done. Drafts from a small "
                + "model need careful review."
        ) {
            if let problem = models.localModelRuntimeProblem {
                SettingsRow(title: "Small models", caption: problem, captionColor: AppColor.error) {
                    EmptyView()
                }
            } else {
                ForEach(models.localModels) { option in
                    VStack(alignment: .leading, spacing: 0) {
                        ModelAssetRow(
                            title: option.name,
                            // "Standard", not "Default": the owner's default model is a different setting (review minor 9).
                            value: option.tier == .quality ? "Quality" : "Standard",
                            status: models.localModelStatus[option.id] ?? .notDownloaded,
                            approximateDownloadBytes: option.downloadBytes,
                            runsOn: Self.runsOn,
                            onDownload: { requestDownload(option) },
                            onDelete: { Task { await models.deleteLocalModel(id: option.id) } }
                        )
                        LocalModelFacts(option: option)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                            .padding(.top, -4)
                    }
                }
            }
        }
        .alert(
            pendingDownload?.notice.title ?? "",
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            presenting: pendingDownload
        ) { pending in
            Button(pending.notice.confirmTitle) { environment.downloadLocalLanguageModel(pending.option) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.notice.message)
        }
        .alert(
            "Couldn’t change the model",
            isPresented: Binding(
                get: { models.localModelError != nil }, set: { if !$0 { models.localModelError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(models.localModelError ?? "")
        }
    }
}

extension OnDeviceModelsSection {
    /// Every current model is over 1 GB and unmeasured, so Download asks first with the size, the memory it needs
    /// against what iOS lets Parakeet use now, and the measurement caution (review I3c).
    fileprivate func requestDownload(_ option: LocalModelOption) {
        if let notice = option.downloadNotice(availableMemoryBytes: MemoryProbe.availableBytes()) {
            pendingDownload = PendingDownload(option: option, notice: notice)
        } else {
            environment.downloadLocalLanguageModel(option)
        }
    }

    /// The phone's GPU; the engine uses the CPU in the Simulator, whose Metal is no stand-in for the phone's GPU.
    fileprivate static var runsOn: String {
        #if targetEnvironment(simulator)
        "CPU (Simulator)"
        #else
        "GPU"
        #endif
    }
}

/// The badge and the facts that decide whether a model fits: memory while in use, window, license, source.
private struct LocalModelFacts: View {
    let option: LocalModelOption
    // F81: the engineering line ("About 2.2 GB of memory in use · 32K-token window · Apache-2.0 ·
    // Qwen/Qwen3.5-2B · Q4_K_M · llama.cpp") sat in the main row unconditionally; it now opens on request instead.
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("On device")
                    .chirpFont(11.5, .bold)
                    .foregroundStyle(Tokens.Color.privacyBadgeInk)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(Capsule().fill(Tokens.Color.privacyBadgeFill))
                Spacer(minLength: 0)
                detailsToggle
            }
            .accessibilityElement(children: .combine)
            if showsDetails {
                Text(facts)
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = option.measurementCaution {
                // Until the model's iPhone numbers are recorded (review I3b); louder for the quality tier.
                Text(caution)
                    .chirpFont(12)
                    .foregroundStyle(option.tier == .quality ? AppColor.error : Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailsToggle: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 3) {
                Text("Details")
                    .chirpFont(12.5, .semibold)
                Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(AppColor.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDetails ? "Hide details" : "Show details")
        .accessibilityValue(facts)
    }

    private var facts: String {
        let window = option.contextTokens >= 1_024 ? "\(option.contextTokens / 1_024)K" : "\(option.contextTokens)"
        return "About \(Formatting.size(bytes: option.memoryBytes)) of memory in use · \(window)-token window · "
            + "\(option.license) · \(option.source) · \(option.runtime)"
    }
}
