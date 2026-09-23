import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Plan 023 (UX audit F43): how a generated document (SOAP note, summary, meeting notes, any template's output) shows
/// in the Library and under "Made from this" on the item it was made from.

/// The cover at the left of a generated document's row: a page with rich text, in the accent ink.
struct GeneratedDocumentCover: View {
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            CardBackground(radius: radius, fill: AppColor.tintFill, stroke: AppColor.tintStroke)
            Image(systemName: "doc.richtext")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(Tokens.Color.accentInk)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A generated document's row content: the item it was made from, the template as a type badge, the class the privacy
/// rules use, the start of the text and when it was made. Not a button itself: the Library wraps it in one, "Made from
/// this" in a navigation link.
struct LibraryDocumentRowContent: View {
    enum Style {
        /// The Library: the source's title leads, with the snippet.
        case full
        /// "Made from this" on the source's own screen: the source is known, so the type leads.
        case madeFromThis
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    let document: LibraryDocument
    let style: Style

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GeneratedDocumentCover(
                size: style == .full ? 52 : 40,
                radius: style == .full ? Tokens.Radius.cover : Tokens.Radius.coverSmall)
            VStack(alignment: .leading, spacing: 0) {
                if style == .full {
                    Text(Self.sourceTitle(document))
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.tail)
                        .padding(.bottom, 5)
                }
                badges
                if style == .full, !document.summary.snippet.isEmpty {
                    Text(document.summary.snippet)
                        .chirpFont(12.8)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .padding(.top, 5)
                }
                Text(Self.meta(for: document, style: style))
                    .chirpFont(style == .full ? 11.5 : 12)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(1)
                    .padding(.top, 5)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Color.mutedText)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(minHeight: style == .full ? 76 : 62, alignment: .top)
        .background(CardBackground(radius: Tokens.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(for: document, style: style))
    }

    /// The type badge and the privacy badge side by side, or stacked when they do not fit (large text).
    private var badges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeItems }
            VStack(alignment: .leading, spacing: 4) { badgeItems }
        }
    }

    @ViewBuilder private var badgeItems: some View {
        DocumentTypeBadge(title: document.typeTitle)
        PrivacyClassBadge(privacyClass: document.effectivePrivacyClass)
    }

    /// The source's title, or a plain statement when this build cannot read the source row.
    static func sourceTitle(_ document: LibraryDocument) -> String {
        document.sourceTitle ?? "Source unavailable"
    }

    /// The Library, under its day's section: "Document · 2:05 PM", like a transcript's "Dictation · 3:04 · 1:23 AM".
    /// "Made from this" has no day sections: "Today 2:05 PM". Either adds "· Edited" when the person edited it.
    static func meta(for document: LibraryDocument, style: Style) -> String {
        let time = Formatting.timeOfDay(document.createdAt)
        let made =
            style == .full ? "Document · \(time)" : Formatting.day(document.createdAt) + " " + time
        return document.summary.editedAt == nil ? made : made + " · Edited"
    }

    /// "SOAP note from Visit 12, Privacy: Clinical, Today 2:05 PM" (the day always, whatever the section says).
    static func accessibilityLabel(for document: LibraryDocument, style: Style) -> String {
        let what =
            style == .full ? "\(document.typeTitle) from \(sourceTitle(document))" : document.typeTitle
        return "\(what), Privacy: \(document.effectivePrivacyClass.title), "
            + meta(for: document, style: .madeFromThis)
    }
}

/// The template's name as a small tinted capsule ("SOAP note").
struct DocumentTypeBadge: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "sparkles")
            .labelStyle(.titleAndIcon)
            .chirpFont(11.5, .semibold)
            .lineLimit(1)
            // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
            .foregroundStyle(AppColor.accentTextOnTint)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(Capsule().fill(AppColor.tintFill))
    }
}

/// "Made from this" on a recording, typed text or imported document: every document made from it, newest first, each
/// opening the document screen. Shows nothing when nothing was made from the item yet. The first three show; "Show all"
/// lists the rest, so none is ever out of reach.
struct MadeFromThisSection: View {
    @Environment(AppEnvironment.self) private var environment
    let sourceID: UUID
    /// Padding around the section when it shows (none when there is nothing to list).
    var padding = EdgeInsets()

    @State private var showsAll = false

    static let collapsedCount = 3

    var body: some View {
        let documents = environment.library.documents(madeFrom: sourceID)
        if !documents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Made from this")
                    .accessibilityAddTraits(.isHeader)
                ForEach(showsAll ? documents : Array(documents.prefix(Self.collapsedCount))) { document in
                    NavigationLink {
                        DeferredDeliverableDetail(id: document.id, environment: environment)
                    } label: {
                        LibraryDocumentRowContent(document: document, style: .madeFromThis)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the document")
                }
                if documents.count > Self.collapsedCount {
                    Button {
                        showsAll.toggle()
                    } label: {
                        Text(showsAll ? "Show fewer" : "Show all \(documents.count)")
                            .chirpFont(14, .semibold)
                            .foregroundStyle(AppColor.accentText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(padding)
        }
    }
}

/// Builds the document screen only when it is pushed: a navigation link builds its destination with every render, and
/// the document screen makes its view model when it is built.
struct DeferredDeliverableDetail: View {
    let id: UUID
    let environment: AppEnvironment

    var body: some View {
        DeliverableDetailScreen(id: id, environment: environment)
    }
}
