import ChirpCore
import ChirpUI
import SwiftUI
import UIKit

/// Settings → About: the owner's pixel-parakeet artwork, the build stamp (owner's rule: every revision is
/// identifiable in the app) and the memory the system still allows the app, a device diagnostic.
struct AboutSection: View {
    @State private var copied = false
    @State private var availableMemory: String = "…"

    private let build = BuildIdentity.current

    var body: some View {
        SettingsGroup(title: "About") {
            artwork
            aboutRow("Version", "\(build.version) (\(build.build))")
            aboutRow("Commit", build.commit, monospaced: true)
            aboutRow("Branch", build.branch, monospaced: true)
            aboutRow("Built", Self.builtDisplayText(build.buildDateUTC), monospaced: true)
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

    /// The owner's "PARAKEET" pixel art (also the launch screen), on its own cream plate so it reads the same in light
    /// and dark mode.
    private var artwork: some View {
        Image("ParakeetArt")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color("LaunchBackground"))
            .accessibilityLabel("Parakeet")
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

    /// F93's non-owner fix: the stamped build date, parsed from `ChirpBuildDateUTC`'s ISO-8601 UTC form, shown
    /// alongside the phone's own local time — the raw UTC string alone read as "wrong" against a local clock.
    /// Falls back to the raw string when it isn't a parseable ISO-8601 timestamp (older builds, "unknown").
    static func builtDisplayText(_ buildDateUTC: String) -> String {
        guard let date = Self.isoFormatter.date(from: buildDateUTC) else { return buildDateUTC }
        return "\(buildDateUTC) · \(Self.localFormatter.string(from: date)) local"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter
    }()
}
