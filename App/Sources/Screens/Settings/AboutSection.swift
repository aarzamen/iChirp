import ChirpCore
import ChirpUI
import SwiftUI
import UIKit

/// Settings → About: the build stamp (owner's rule: every revision is identifiable in the app) plus the memory the
/// system still allows the app, a device diagnostic.
struct AboutSection: View {
    @State private var copied = false
    @State private var availableMemory: String = "…"

    private let build = BuildIdentity.current

    var body: some View {
        SettingsGroup(title: "About") {
            aboutRow("Version", "\(build.version) (\(build.build))")
            aboutRow("Commit", build.commit, monospaced: true)
            aboutRow("Branch", build.branch, monospaced: true)
            aboutRow("Built", build.buildDateUTC, monospaced: true)
            aboutRow("Working tree", build.isDirty ? "Uncommitted changes" : "Clean")
            aboutRow("Available memory", availableMemory)
            Button {
                UIPasteboard.general.string = Self.buildInfo(build)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                HStack {
                    Text(copied ? "Copied" : "Copy build info")
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(AppColor.accentText)
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(AppColor.accentText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .task {
            availableMemory = Self.availableMemoryText()
        }
    }

    private func aboutRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        SettingsRow(title: title) {
            Text(value)
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(Tokens.Color.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    /// The text "Copy build info" puts on the clipboard.
    static func buildInfo(_ build: BuildIdentity) -> String {
        "Parakeet \(build.summary)"
    }

    static func availableMemoryText() -> String {
        guard let bytes = MemoryProbe.availableBytes() else { return "Not reported here" }
        return "\(MemoryProbe.megabytes(bytes).formatted()) MB"
    }
}
