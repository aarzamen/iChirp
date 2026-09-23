// UX audit F23 / plan 023 owner decision: generated documents render their Markdown on screen — headings, bulleted
// and numbered lists, bold, italics — instead of showing `**`/`##` literally. `PlainTextFlattener` is this view's
// Copy-side twin.

import SwiftUI

/// How `MarkdownDocument` draws each block. Every default is a Dynamic-Type-following system text style, so the
/// view works with no configuration at all; an app with its own design tokens overrides colors and fonts to match
/// (iChirp's own `MarkdownDocumentStyle.chirp` lives in `App/Sources/Design`, next to `chirpFont`).
public struct MarkdownDocumentStyle: Sendable {
    public var textColor: Color
    public var secondaryColor: Color
    public var bodyFont: Font
    public var codeFont: Font
    /// The font for a heading at a given level (1–6 for a real `#` heading, 2 for a bold-only pseudo-heading).
    public var headingFont: @Sendable (Int) -> Font
    public var blockSpacing: CGFloat
    public var listRowSpacing: CGFloat
    /// Extra leading padding per `MarkdownListItem.level` of nesting.
    public var listIndent: CGFloat

    public init(
        textColor: Color = .primary,
        secondaryColor: Color = .secondary,
        bodyFont: Font = .body,
        codeFont: Font = .system(.body, design: .monospaced),
        headingFont: @escaping @Sendable (Int) -> Font = MarkdownDocumentStyle.systemHeadingFont,
        blockSpacing: CGFloat = 14,
        listRowSpacing: CGFloat = 6,
        listIndent: CGFloat = 18
    ) {
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.headingFont = headingFont
        self.blockSpacing = blockSpacing
        self.listRowSpacing = listRowSpacing
        self.listIndent = listIndent
    }

    /// Level 1 (a real top-level `#`) is `.title2`; everything else — a real `##`+ or a template's bold-only
    /// section name — is `.headline`. Both are relative system text styles, so both track Dynamic Type with no
    /// extra plumbing (a fixed `.system(size:)` font would not).
    public static func systemHeadingFont(_ level: Int) -> Font {
        (level <= 1 ? Font.title2 : Font.headline).bold()
    }

    public static let `default` = MarkdownDocumentStyle()
}

/// Renders a generated document's Markdown: headings, bulleted and numbered lists (nested lists indent further),
/// bold and italic text. Pure SwiftUI over `MarkdownBlockParser`/`MarkdownInline` — no third-party dependency.
///
/// - Dynamic Type: every font in `MarkdownDocumentStyle.default` is a relative system text style.
/// - Text selection: `.textSelection(.enabled)` is applied once, at the top.
/// - VoiceOver: a heading carries `.isHeader` and `.accessibilityHeading(_:)`, so the rotor can jump between
///   sections the way it does on any other screen.
public struct MarkdownDocument: View {
    private let blocks: [MarkdownBlock]
    private let style: MarkdownDocumentStyle

    public init(_ markdown: String, style: MarkdownDocumentStyle = .default) {
        self.blocks = MarkdownBlockParser.parse(markdown)
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockContent(block: block, style: style)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockContent: View {
    let block: MarkdownBlock
    let style: MarkdownDocumentStyle

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(style.headingFont(level))
                .foregroundStyle(style.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.accessibilityLevel(level))
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .font(style.bodyFont)
                .foregroundStyle(style.textColor)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: style.listRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListItemRow(item: item, style: style)
                }
            }
        case .code(let text):
            Text(text)
                .font(style.codeFont)
                .foregroundStyle(style.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func accessibilityLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

private struct MarkdownListItemRow: View {
    let item: MarkdownListItem
    let style: MarkdownDocumentStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.number.map { "\($0)." } ?? "•")
                .font(style.bodyFont)
                .foregroundStyle(style.secondaryColor)
                .frame(minWidth: 18, alignment: .trailing)
                .accessibilityHidden(true)
            Text(MarkdownInline.attributed(item.text))
                .font(style.bodyFont)
                .foregroundStyle(style.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.level) * style.listIndent)
        .accessibilityElement(children: .combine)
    }
}
