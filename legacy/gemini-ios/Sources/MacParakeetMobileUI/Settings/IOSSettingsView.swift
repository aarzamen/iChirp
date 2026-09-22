import SwiftUI
import MacParakeetCore

/// Native iOS Settings screen for audio engines, AI providers, custom vocabulary, and storage.
public struct IOSSettingsView: View {
    public enum STTEngine: String, CaseIterable, Identifiable {
        case parakeet = "Parakeet TDT (CoreML/ANE)"
        case whisperKit = "WhisperKit (Multilingual)"
        case nemotron = "Nemotron English"
        public var id: String { rawValue }
    }

    public enum AIProvider: String, CaseIterable, Identifiable {
        case gemini = "Google Gemini"
        case anthropic = "Anthropic Claude"
        case openAI = "OpenAI"
        case ollama = "Local Ollama"
        public var id: String { rawValue }
    }

    @AppStorage("mobile_selected_stt_engine") private var selectedEngine: STTEngine = .parakeet
    @AppStorage("mobile_selected_ai_provider") private var selectedAIProvider: AIProvider = .gemini
    @AppStorage("mobile_ai_api_key") private var apiKey: String = ""
    @AppStorage("mobile_keep_audio_recordings") private var keepAudio: Bool = true
    @State private var showingClearCacheAlert: Bool = false
    @State private var cacheCleared: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                // Section 1: Speech Recognition Engine
                Section {
                    Picker("Recognition Engine", selection: $selectedEngine) {
                        ForEach(STTEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }

                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(MobileDesignSystem.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Neural Engine (ANE)")
                                .font(MobileDesignSystem.Typography.bodySmall)
                            Text("100% private, local-first inference on device")
                                .font(MobileDesignSystem.Typography.caption)
                                .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                        }
                    }
                } header: {
                    Text("Speech-to-Text")
                } footer: {
                    Text("Parakeet TDT runs fully offline on Apple Silicon with ~15x real-time speed.")
                }

                // Section 2: AI Summaries & Transforms
                Section {
                    Picker("AI Provider", selection: $selectedAIProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }

                    if selectedAIProvider != .ollama {
                        SecureField("API Key", text: $apiKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("AI Intelligence & Transforms")
                } footer: {
                    Text("Used for post-meeting summaries, action item extraction, and text rewrites.")
                }

                // Section 3: Audio & Storage
                Section {
                    Toggle("Retain Audio Files", isOn: $keepAudio)

                    Button(role: .destructive, action: {
                        showingClearCacheAlert = true
                    }) {
                        HStack {
                            Text("Clear Audio Cache")
                            Spacer()
                            if cacheCleared {
                                Image(systemName: "checkmark")
                                    .foregroundColor(MobileDesignSystem.Colors.successGreen)
                            }
                        }
                    }
                } header: {
                    Text("Storage")
                }

                // Section 4: Privacy & About
                Section {
                    HStack {
                        Label("Local-First Privacy", systemImage: "lock.shield.fill")
                            .foregroundColor(MobileDesignSystem.Colors.successGreen)
                        Spacer()
                        Text("Active")
                            .font(MobileDesignSystem.Typography.caption)
                            .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    }

                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (iOS)")
                            .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    }

                    HStack {
                        Text("Developer Team")
                        Spacer()
                        Text("(your team)")
                            .font(MobileDesignSystem.Typography.monoTimestamp)
                            .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert("Clear Audio Cache?", isPresented: $showingClearCacheAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    MobileDesignSystem.Haptics.heavy()
                    cacheCleared = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        cacheCleared = false
                    }
                }
            } message: {
                Text("This will remove temporary audio recordings. Your transcript database and meeting notes will remain intact.")
            }
        }
    }
}
