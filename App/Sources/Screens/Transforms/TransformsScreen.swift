import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 3: the generated documents, newest first, a page at a time ("Show more" reaches every one; UX audit F43), and
/// every template (tap one to run it on a transcript). Transcript → Transform runs the same templates on the transcript
/// at hand. Plan 023: this tab is where a transform starts; every document also lives in the Library (Documents
/// filter), which "See all in Library" opens.
struct TransformsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// Switches tabs (RootTabView); nil hides "See all in Library".
    var openTab: ((AppTab) -> Void)?
    @State private var launching: PromptTemplate?

    var body: some View {
        let library = environment.deliverableLibrary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transforms")
                        .chirpTitleFont(28, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Turn transcripts into the documents you need. They run "
                            + "\(environment.languageModels.defaultChoice.place); change that in Settings → Models."
                    )
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                    if let error = library.loadError {
                        Text("Couldn’t read your documents: \(error)")
                            .chirpFont(13)
                            .foregroundStyle(AppColor.error)
                            .padding(.top, 12)
                    }
                    recentSection(library.recent, hasMore: library.hasMore)
                    templateSection("Documents", library.documentTemplates)
                    templateSection("Rewrites", library.transformTemplates)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .statusBarScrim()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                DeliverableDetailScreen(id: id, environment: environment)
            }
            .refreshable { await library.load() }
        }
        .task { await library.load() }
        .sheet(item: $launching, onDismiss: { Task { await library.load() } }) { template in
            TemplateLaunchSheet(template: template, environment: environment)
        }
    }

    @ViewBuilder private func recentSection(_ recent: [Deliverable], hasMore: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Recent documents")
                Spacer(minLength: 8)
                seeAllInLibrary(showing: !recent.isEmpty)
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Recent documents")
                seeAllInLibrary(showing: !recent.isEmpty)
            }
        }
        .padding(.leading, 4)
        .padding(.top, 20)
        .padding(.bottom, 8)
        if recent.isEmpty {
            Text("Nothing yet. Open a transcript and tap Transform, or pick a template below.")
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chirpCard(radius: Tokens.Radius.m, padding: 14)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(recent) { deliverable in
                    // R7-7: the Library's own document row, so the same document looks the same in both places
                    // (source title first, type and effective-class badges).
                    NavigationLink(value: deliverable.id) {
                        LibraryDocumentRowContent(document: libraryDocument(deliverable), style: .full)
                    }
                    .buttonStyle(.plain)
                }
                if hasMore {
                    Button("Show older documents") {
                        Task { await environment.deliverableLibrary.showMore() }
                    }
                    .buttonStyle(.chirpSecondary)
                    .padding(.top, 4)
                    .accessibilityHint("Adds the next older documents to this list")
                }
            }
        }
    }

    /// Plan 023: every document is in the Library; this opens it on the Documents filter.
    @ViewBuilder private func seeAllInLibrary(showing: Bool) -> some View {
        if showing, let openTab {
            Button {
                environment.library.searchText = ""
                environment.library.filter = .documents
                openTab(.library)
            } label: {
                Text("See all in Library")
                    .chirpFont(13.5, .semibold)
                    .foregroundStyle(AppColor.accentText)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Library on the Documents filter")
        }
    }

    @ViewBuilder private func templateSection(_ title: String, _ templates: [PromptTemplate]) -> some View {
        if !templates.isEmpty {
            SectionLabel(title)
                .padding(.leading, 4)
                .padding(.top, 20)
                .padding(.bottom, 8)
            VStack(spacing: 8) {
                ForEach(templates) { template in
                    Button {
                        launching = template
                    } label: {
                        TemplateRow(template: template, trailing: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Choose a transcript to run it on")
                }
            }
        }
    }

    /// The Library's row for `deliverable`: the Library's own entry when it has one (the same effective class), else
    /// one joined here the same way (`LibraryViewModel`: the stricter of the document, its source and the source's
    /// other documents; clinical when the source is not in the Library).
    private func libraryDocument(_ deliverable: Deliverable) -> LibraryDocument {
        Self.libraryDocument(deliverable, library: environment.library)
    }

    static func libraryDocument(_ deliverable: Deliverable, library: LibraryViewModel) -> LibraryDocument {
        if let listed = library.documents.first(where: { $0.id == deliverable.id }) { return listed }
        let source = library.items.first { $0.id == deliverable.transcriptionID }
        let siblings = library.documents(madeFrom: deliverable.transcriptionID).map(\.summary.privacyClass)
        let strictest = siblings.reduce(deliverable.privacyClass) { $0.stricter($1) }
        return LibraryDocument(
            summary: DeliverableSummary(deliverable), sourceTitle: source?.displayTitle, sourceType: source?.sourceType,
            effectivePrivacyClass: (source?.privacyClass ?? .clinical).stricter(strictest))
    }
}
