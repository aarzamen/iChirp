import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 2 (canvas `Library.dc.html`): search, filter chips, day sections and rows. Swipe a row to delete (with
/// confirmation) or favorite it.
///
/// Polish (UX audit X): 44 pt targets for the chips, the layout toggle and Clear search, one name for favorites
/// ("Favorite" / "Unfavorite"), and empty states that say what to do. The filters themselves are unchanged (F63 and
/// the documents filter are owner decisions for a later lane).
struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var path: [UUID] = []
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
            .navigationDestination(for: UUID.self) { id in
                LibraryItemScreen(id: id, environment: environment)
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

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryViewModel.Filter.allCases, id: \.self) { filter in
                    chip(filter)
                }
            }
        }
        .scrollClipDisabled()
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
                } else if library.items.isEmpty {
                    EmptyStateView(
                        title: "Your library is empty",
                        message: "Tap Create on Capture to speak, type, paste a link or pick a file. Everything you "
                            + "make lands here.")  // F65
                } else if library.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // F68: an empty filter is not a failed search.
                    EmptyStateView(title: "Nothing here yet", message: "Nothing in \(library.filter.title) yet.")
                } else {
                    EmptyStateView(
                        title: "No matches",
                        message: "Nothing matches “\(library.searchText)” in \(library.filter.title).")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .padding(.top, 20)
        } else {
            List {
                ForEach(sections, id: \.title) { section in
                    SectionLabel(section.title)
                        .listRowInsets(EdgeInsets(top: 12, leading: 28, bottom: 10, trailing: 24))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, 8, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    private func row(_ item: Transcription) -> some View {
        LibraryItemRow(
            item: item,
            progress: environment.jobCenter.progress[item.id],
            compact: false,
            onOpen: { path.append(item.id) },
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
            .tint(AppColor.error)
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
            Text(LibraryDeleteCopy.message(for: item))
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

    // MARK: - Actions

    private func delete(_ item: Transcription) async {
        do {
            try await environment.delete(item.id)
            path.removeAll { $0 == item.id }
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

/// The delete question for a Library item, shared by the Library and the Transcript screen's More → Delete…
///
/// Deleting a row also deletes the documents made from it (the `deliverables` foreign key cascades), so the message
/// says so.
enum LibraryDeleteCopy {
    static func title(for item: Transcription) -> String {
        item.isTextItem
            ? "Delete this text?" : item.isDocument ? "Delete this document?" : "Delete transcript and its audio?"
    }

    static func message(for item: Transcription) -> String {
        let name = "“\(item.displayTitle)”"
        let what =
            item.isTextItem
            ? "\(name) and anything made from it"
            : item.isDocument
                ? "\(name), its copy of the file and anything made from it"
                : "\(name), its audio and any documents made from it"
        return "\(what) will be removed from this iPhone. This can’t be undone."
    }
}
