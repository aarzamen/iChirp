import ChirpUI
import SwiftUI

/// Tab 3: the Transforms and deliverable templates planned for milestone M4. A read-only list; nothing here
/// pretends to run.
struct TransformsScreen: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let summary: String
        let systemImage: String
    }

    static let items: [Item] = [
        Item(
            id: "polish", title: "Polish", summary: "Clean up the wording, keep your voice",
            systemImage: "wand.and.stars"),
        Item(
            id: "distill", title: "Distill", summary: "Cut to the essential points",
            systemImage: "line.3.horizontal.decrease"),
        Item(id: "decide", title: "Decide", summary: "Turn this into a recommendation", systemImage: "scalemass"),
        Item(
            id: "brief", title: "Brief", summary: "A custom Transform template · BLUF, then three bullets",
            systemImage: "doc.text"),
        Item(
            id: "meeting-notes", title: "Meeting notes", summary: "Summary, decisions and owners from a meeting",
            systemImage: "person.2"),
        Item(
            id: "soap-note", title: "SOAP note", summary: "Subjective, objective, assessment and plan",
            systemImage: "stethoscope"),
        Item(
            id: "agenda", title: "Agenda", summary: "Topics and time boxes for the next meeting",
            systemImage: "list.number"),
        Item(id: "action-items", title: "Action items", summary: "Who does what, by when", systemImage: "checklist"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transforms")
                        .chirpTitleFont(28, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Rewrite transcripts and selected text into the documents you need. Not built yet — "
                            + "milestone M4. They will run on device unless you choose a cloud model."
                    )
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                    VStack(spacing: 8) {
                        ForEach(Self.items) { item in
                            row(item)
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppColor.tintFill)
                Image(systemName: item.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accentInk)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .chirpFont(15.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(item.summary)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("Milestone M4")
                .chirpFont(10.5, .bold)
                .foregroundStyle(AppColor.accentText)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(Capsule().fill(AppColor.tintFill))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 68)
        .background(CardBackground(radius: Tokens.Radius.m))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.summary), not built yet, milestone M4")
    }
}
