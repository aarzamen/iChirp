import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Models → "Small models on this iPhone" (M7, ADR-015): each llama.cpp model with its size, memory, window
/// and license, an on-device badge, and Download / Delete. A downloaded model becomes a choice for Transform and Ask
/// above; clinical items may use it without a confirmation because nothing leaves the phone.
struct OnDeviceModelsSection: View {
    @Environment(AppEnvironment.self) private var environment

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
                            value: option.tier == .quality ? "Quality" : "Default",
                            status: models.localModelStatus[option.id] ?? .notDownloaded,
                            approximateDownloadBytes: option.downloadBytes,
                            runsOn: Self.runsOn,
                            onDownload: { environment.downloadLocalLanguageModel(option) },
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("On device")
                .chirpFont(11.5, .bold)
                .foregroundStyle(Tokens.Color.privacyBadgeInk)
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(Capsule().fill(Tokens.Color.privacyBadgeFill))
            Text(facts)
                .chirpFont(12)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var facts: String {
        let window = option.contextTokens >= 1_024 ? "\(option.contextTokens / 1_024)K" : "\(option.contextTokens)"
        return "About \(Formatting.size(bytes: option.memoryBytes)) of memory in use · \(window)-token window · "
            + "\(option.license) · \(option.source) · \(option.runtime)"
    }
}
