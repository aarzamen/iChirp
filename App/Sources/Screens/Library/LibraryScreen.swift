import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Tab 2 (canvas `Library.dc.html`): search, filter chips, day sections and rows. Swipe a row to delete (with
/// confirmation) or star it.
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

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            Button {
                placeholder = .gridLayout
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .frame(width: 44, height: 30)
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
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppColor.quietFill))
    }

    private var searchField: some View {
        @Bindable var library = environment.library
        return HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.secondary)
                .accessibilityHidden(true)
            TextField("Search transcripts, speakers, labels", text: $library.searchText)
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
                        .frame(width: 30, height: 30)
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
                .foregroundStyle(selected ? AppColor.accentText : Tokens.Color.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(
                    Capsule().fill(selected ? AppColor.tintFill : Tokens.Color.surface)
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? AppColor.tintStrokeSelected : Tokens.Color.border, lineWidth: 1))
                )
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
                        message: "Import audio from Capture. Every transcript lands here, searchable and on device.")
                } else {
                    EmptyStateView(
                        title: "No matches",
                        message: library.searchText.isEmpty
                            ? "Nothing in \(library.filter.title) yet."
                            : "Nothing matches “\(library.searchText)” in \(library.filter.title).")
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
                Label(item.isFavorite ? "Unstar" : "Star", systemImage: item.isFavorite ? "star.slash" : "star")
            }
            .tint(Tokens.Color.favorite)
        }
        .confirmationDialog(
            item.isDocument ? "Delete this document?" : "Delete transcript and its audio?",
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
                item.isDocument
                    ? "“\(item.displayTitle)” and its copy of the file will be removed from this iPhone. This can’t be undone."
                    : "“\(item.displayTitle)” and its audio will be removed from this iPhone. This can’t be undone.")
        }
        .contextMenu {
            Button {
                Task { await toggleFavorite(item) }
            } label: {
                Label(
                    item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
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
