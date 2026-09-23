import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 2 (canvas `Library.dc.html`): search, filter chips, day sections and rows. Swipe a row to delete (with
/// confirmation) or favorite it.
///
/// Polish (UX audit X): 44 pt targets for the chips, the layout toggle and Clear search, one name for favorites
/// ("Favorite" / "Unfavorite"), and empty states that say what to do. F63 (renaming the source filters) is still the
/// owner's decision.
///
/// Plan 023 (UX audit F43): generated documents are rows here too, next to what they were made from, with a Documents
/// filter; search reads their text. Rows arrive a page at a time (the next page loads as the last row appears), so a
/// Library of thousands stays smooth and every row is reachable. A document opens the document screen, whose More menu
/// keeps its own Delete.
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var path: [LibraryRoute] = []
    @State private var pendingDelete: Transcription?
    @State private var placeholder: Placeholder?
    @State private var actionError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(Tokens.Color.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .item(let id): LibraryItemScreen(id: id, environment: environment)
                case .document(let id): DeliverableDetailScreen(id: id, environment: environment)
                }
            }
        }
        .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { actionError != nil || environment.library.loadError != nil },
                set: { presented in
                    if !presented {
                        actionError = nil
                        environment.library.dismissLoadError()
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? environment.library.loadError ?? "")
        }
    }

    // MARK: - Header (fixed, like the canvas)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Library")
                    .chirpTitleFont(28, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                layoutToggle
            }
            .frame(minHeight: 44)
            searchField
            chips
            if let error = environment.library.searchError {
                Text("Couldn’t search inside documents: \(error)")
                    .chirpFont(12.5)
                    .foregroundStyle(AppColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !environment.pendingMeetingRecoveries.isEmpty {
                MeetingRecoveryBanner()  // M3: meetings a killed launch left behind
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// The canvas's 36 pt segmented look; the Grid button's target is the full 44 pt height (F64).
    private var layoutToggle: some View {
        HStack(spacing: 2) {
            Button {
                placeholder = .gridLayout
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .frame(width: 44, height: 30)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Grid layout, not built yet")
            Image(systemName: "list.bullet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.ink)
                .frame(width: 44, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Tokens.Color.surface)
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                )
                .accessibilityLabel("List layout, selected")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppColor.quietFill).frame(height: 36))
    }

    private var searchField: some View {
        @Bindable var library = environment.library
        return HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.secondary)
                .accessibilityHidden(true)
            TextField("Search titles, text and speakers", text: $library.searchText)  // F68: no "labels" exist
                .chirpFont(14.5)
                .foregroundStyle(Tokens.Color.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !library.searchText.isEmpty {
                Button {
                    library.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.Color.mutedText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(CardBackground(radius: Tokens.Radius.cover))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    /// The selected chip scrolls into view, also when another screen picks the filter (Transforms → "See all in
    /// Library" selects Documents, the last chip).
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LibraryViewModel.Filter.allCases, id: \.self) { filter in
                        chip(filter).id(filter)
                    }
                }
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(environment.library.filter) }
            .onChange(of: environment.library.filter) { _, filter in
                withAnimation { proxy.scrollTo(filter) }
            }
        }
    }

    private func chip(_ filter: LibraryViewModel.Filter) -> some View {
        let selected = environment.library.filter == filter
        return Button {
            environment.library.filter = filter
        } label: {
            Text(filter.title)
                .chirpFont(13.5, .semibold)
                // Text-safe ink on the selected chip's tint fill (F8): `accentText` alone is 4.39:1 there.
                .foregroundStyle(selected ? AppColor.accentTextOnTint : Tokens.Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(
                    Capsule().fill(selected ? AppColor.tintFill : Tokens.Color.surface)
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? AppColor.tintStrokeSelected : Tokens.Color.border, lineWidth: 1))
                )
                .frame(minHeight: 44)  // F64: a 34 pt capsule in a 44 pt target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        let library = environment.library
        let sections = library.sections
        if sections.isEmpty {
            ScrollView {
                if !environment.isLaunched {
                    EmptyView()
                } else if library.items.isEmpty && library.documents.isEmpty {
                    EmptyStateView(
                        title: "Your library is empty",
                        message: "Tap Create on Capture to speak, type, paste a link or pick a file. Everything you "
                            + "make lands here.")  // F65
                } else if library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if library.filter == .documents {
                        EmptyStateView(
                            title: "No documents yet",
                            message: "SOAP notes, summaries and everything else you make from a recording or text "
                                + "appear here. Open an item and tap Transform, or use Create.")
                    } else {
                        // F68: an empty filter is not a failed search.
                        EmptyStateView(title: "Nothing here yet", message: "Nothing in \(library.filter.title) yet.")
                    }
                } else {
                    EmptyStateView(
                        title: library.isSearching ? "Searching…" : "No matches",
                        message: "Nothing matches “\(library.searchText)” in \(library.filter.title).")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .padding(.top, 20)
        } else {
            ScrollViewReader { proxy in
                list(sections, hasMore: library.hasMore)
                    // A new filter or search starts at its newest row, not wherever the last list was scrolled.
                    .onChange(of: library.filter) { _, _ in scrollToTop(proxy) }
                    .onChange(of: library.searchText) { _, _ in scrollToTop(proxy) }
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let first = environment.library.sections.first else { return }
        proxy.scrollTo(first.id, anchor: .top)
    }

    private func list(_ sections: [LibrarySection], hasMore: Bool) -> some View {
        List {
            ForEach(sections) { section in
                SectionLabel(section.title)
                    .id(section.id)
                    .listRowInsets(EdgeInsets(top: 12, leading: 28, bottom: 10, trailing: 24))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                ForEach(section.entries) { entry in
                    switch entry {
                    case .item(let item): row(item)
                    case .document(let document): documentRow(document)
                    }
                }
            }
            if hasMore {
                moreFooter
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.top, 8, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 1)
    }

    /// The next page loads as this footer scrolls into view; the button does the same for anyone who gets here
    /// another way (VoiceOver, Switch Control).
    private var moreFooter: some View {
        Button {
            environment.library.showMore()
        } label: {
            Text("Show older items")
                .chirpFont(14, .semibold)
                // Text-safe ink on the tint fill (F8).
                .foregroundStyle(AppColor.accentTextOnTint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Capsule().fill(AppColor.tintFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds the next older items to this list")
        .onAppear { environment.library.showMore() }
        .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 16, trailing: 24))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func row(_ item: Transcription) -> some View {
        LibraryItemRow(
            item: item,
            progress: environment.jobCenter.progress[item.id],
            compact: false,
            onOpen: { path.append(.item(item.id)) },
            onRetry: { environment.retry(item.id) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 9, trailing: 24))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDelete = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(Tokens.Color.stopRed)
            Button {
                Task { await toggleFavorite(item) }
            } label: {
                Label(
                    LibraryFavoriteCopy.title(isFavorite: item.isFavorite),
                    systemImage: item.isFavorite ? "star.slash" : "star")
            }
            .tint(Tokens.Color.favorite)
        }
        .confirmationDialog(
            LibraryDeleteCopy.title(for: item),
            isPresented: Binding(
                get: { pendingDelete?.id == item.id },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await delete(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LibraryDeleteCopy.message(
                    for: item,
                    documentTitles: environment.library.documents(madeFrom: item.id).map(\.typeTitle)))
        }
        .contextMenu {
            Button {
                Task { await toggleFavorite(item) }
            } label: {
                Label(
                    LibraryFavoriteCopy.title(isFavorite: item.isFavorite),
                    systemImage: item.isFavorite ? "star.slash" : "star")
            }
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    /// A generated document. No swipe actions: its Delete stays on the document screen (More → Delete Document).
    private func documentRow(_ document: LibraryDocument) -> some View {
        Button {
            path.append(.document(document.id))
        } label: {
            LibraryDocumentRowContent(document: document, style: .full)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the document")
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 9, trailing: 24))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            if document.sourceTitle != nil {
                Button {
                    path.append(.item(document.summary.transcriptionID))
                } label: {
                    Label("Show Source", systemImage: "arrow.up.forward.square")
                }
            }
        }
    }

    // MARK: - Actions

    private func delete(_ item: Transcription) async {
        do {
            try await environment.delete(item.id)
            path.removeAll { $0 == .item(item.id) }
        } catch {
            actionError = Formatting.message(for: error)
        }
    }

    private func toggleFavorite(_ item: Transcription) async {
        do {
            try await environment.library.toggleFavorite(item.id)
        } catch {
            actionError = Formatting.message(for: error)
        }
    }
}

/// One name for the star everywhere (F67): the Library's swipe and menu and the Transcript screen.
enum LibraryFavoriteCopy {
    static func title(isFavorite: Bool) -> String {
        isFavorite ? "Unfavorite" : "Favorite"
    }
}

/// Where a Library row leads: a recording, text item or imported file, or a generated document (plan 023).
enum LibraryRoute: Hashable {
    case item(UUID)
    case document(UUID)
}

/// The delete question for a Library item, shared by the Library and the Transcript screen's More → Delete…
///
/// Deleting a row also deletes the documents made from it (the `deliverables` foreign key cascades), so the message
/// says so, and names them when the caller knows them (plan 023: "the 2 documents made from it (SOAP note, Summary)").
enum LibraryDeleteCopy {
    static func title(for item: Transcription) -> String {
        item.isTextItem
            ? "Delete this text?" : item.isDocument ? "Delete this document?" : "Delete transcript and its audio?"
    }

    /// - Parameter documentTitles: the template names of the documents made from `item`, newest first.
    static func message(for item: Transcription, documentTitles: [String] = []) -> String {
        let name = "“\(item.displayTitle)”"
        let made = documentsPhrase(documentTitles)
        let what =
            item.isTextItem
            ? "\(name) and \(made ?? "anything made from it")"
            : item.isDocument
                ? "\(name), its copy of the file and \(made ?? "anything made from it")"
                : "\(name), its audio and \(made ?? "any documents made from it")"
        return "\(what) will be removed from this iPhone. This can’t be undone."
    }

    /// "the document made from it (SOAP note)", "the 5 documents made from it (SOAP note, Summary, Agenda and 2 more)";
    /// nil when there are none.
    static func documentsPhrase(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        if titles.count == 1 { return "the document made from it (\(titles[0]))" }
        let shown = titles.prefix(3).joined(separator: ", ")
        let rest = titles.count - 3
        let list = rest > 0 ? "\(shown) and \(rest) more" : shown
        return "the \(titles.count) documents made from it (\(list))"
    }
}
