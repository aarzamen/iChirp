import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Capture's header chip, true for the current settings (UX audit F13): "On device" only when every default route runs
/// on this iPhone, "Home network" when a Mac or server at home is used, "Cloud on" when anything goes over the
/// internet. Tapping it opens `WhereThingsRunSheet`.
struct ContentReachChip: View {
    let reach: ContentReach
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            chip
                .frame(minHeight: 44)  // the hit area; the chip keeps its canvas size
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reach.accessibilityLabel)
        .accessibilityHint("Shows where each step runs")
    }

    @ViewBuilder private var chip: some View {
        switch reach.level {
        case .onDevice: StatusChip.onDevice()
        case .homeNetwork: StatusChip(reach.chipTitle, icon: .system("house.fill"))
        case .cloud: StatusChip(reach.chipTitle, icon: .system("icloud"))
        }
    }
}

/// "Where things run": each feature and where its text goes with the current settings, what happens to clinical text,
/// and a way to Settings. Reads settings only; nothing is sent.
struct WhereThingsRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reach: ContentReach
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(reach.summary)
                        .chirpFont(15)
                        .foregroundStyle(Tokens.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(reach.routes) { route in
                            if route.id != reach.routes.first?.id {
                                Rectangle().fill(AppColor.quietFill).frame(height: 1)
                            }
                            row(route)
                        }
                    }
                    .background(CardBackground(radius: Tokens.Radius.m))
                    if !reach.otherCloudModels.isEmpty {
                        note(
                            "Also set up: \(reach.otherCloudModels.joined(separator: ", ")) (over the internet), used "
                                + "only when you choose it for a run. Each run shows where it goes.",
                            systemImage: "icloud")
                    }
                    note(
                        "Clinical items, and anything with a SOAP note, never leave this iPhone for the cloud or an "
                            + "untrusted computer without asking you first, every time. Jev never sees them.",
                        systemImage: "cross.case")
                    Button {
                        dismiss()
                        openSettings()
                    } label: {
                        Text("Open Settings")
                            .chirpFont(15, .semibold)
                            .foregroundStyle(AppColor.accentText)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Capsule().fill(AppColor.tintFill))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Models, voices and Jev are set there")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .navigationTitle("Where things run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(AppColor.accentText)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ route: ContentReach.Route) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: Self.symbol(route.locality))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(route.locality == .cloud ? AppColor.accentText : Tokens.Color.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.feature)
                    .chirpFont(14.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(route.place)
                    .chirpFont(13.5)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = route.note {
                    Text(note)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Tokens.Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.quietFill, stroke: .clear))
    }

    static func symbol(_ locality: EngineLocality?) -> String {
        switch locality {
        case .onDevice?: "iphone"
        case .localNetwork?: "house"
        case .cloud?: "icloud"
        case nil: "minus.circle"
        }
    }
}
