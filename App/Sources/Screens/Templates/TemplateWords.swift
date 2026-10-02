import ChirpCore
import ChirpFeatures
import Foundation

// Plan 026: every word the template screens say, in one file, so the owner's open naming decision (plan 023 F44:
// Transform / Transforms / Document / Rewrites / template) is one edit. Sentences the store or view models return
// (problems, the delete question, provenance lines) live with those types in ChirpKit and are tested there.

enum TemplateWords {
    // MARK: Names

    static let screenTitle = "Templates"
    static let headerEdit = "Edit"
    static let documentsSection = "Documents"
    static let rewritesSection = "Rewrites"
    static let deletedSection = "Deleted templates"
    static let newTemplate = "New template"
    static let hiddenCaption = "Hidden"
    static let reorder = "Reorder"
    static let finish = "Finish"

    static func sectionTitle(_ category: PromptTemplate.Category) -> String {
        category == .deliverable ? documentsSection : rewritesSection
    }

    // MARK: Rows

    /// A built-in's own line, or "Your template".
    static func rowSubtitle(_ template: PromptTemplate) -> String {
        TemplateStyle.of(template).summary
    }

    /// "Clinic SOAP, your template, clinical, hidden" / "SOAP note, built-in, clinical".
    static func accessibilityLabel(_ template: PromptTemplate) -> String {
        var parts = [template.name, template.isBuiltIn ? "built-in" : "your template"]
        if template.outputPrivacyClass == .clinical { parts.append("clinical") }
        if !template.isVisible { parts.append("hidden") }
        return parts.joined(separator: ", ")
    }

    /// The whole row for VoiceOver: the label, then a built-in's own line.
    static func spokenRow(_ template: PromptTemplate) -> String {
        template.isBuiltIn ? "\(accessibilityLabel(template)). \(rowSubtitle(template))" : accessibilityLabel(template)
    }

    static func actionTitle(_ action: TemplateAction) -> String {
        switch action {
        case .duplicateAndEdit: "Duplicate and edit"
        case .edit: "Edit"
        case .duplicate: "Duplicate"
        case .hide: "Hide"
        case .show: "Show"
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .viewInstructions: "View instructions"
        case .delete: "Delete…"
        }
    }

    static func actionImage(_ action: TemplateAction) -> String {
        switch action {
        case .duplicateAndEdit, .duplicate: "plus.square.on.square"
        case .edit: "pencil"
        case .hide: "eye.slash"
        case .show: "eye"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .viewInstructions: "doc.text.magnifyingglass"
        case .delete: "trash"
        }
    }

    /// "Edit, hide or move Clinic SOAP".
    static func menuLabel(_ template: PromptTemplate) -> String {
        template.isBuiltIn ? "Duplicate, hide or move \(template.name)" : "Edit, hide, move or delete \(template.name)"
    }

    // MARK: Screen

    static let screenFooter =
        "Hidden templates stay out of Transform and Create but keep working in your recipes and documents."
    static let emptyCardTitle = "Make a template your way"
    static let emptyCardMessage =
        "Your clinic’s SOAP layout, a referral letter, patient instructions. Start from SOAP note or any template, or "
        + "from a blank page."
    static let deletedFooter = "Restore brings a template back with its versions; recipes that use it run again."
    static let restore = "Restore"
    static let deleteConfirm = "Delete template"
    static let keep = "Keep it"

    /// "1 hidden template. Show it in Templates." / "3 hidden templates. Show them in Templates."
    static func hiddenNote(_ count: Int) -> String {
        count == 1
            ? "1 hidden template. Show it in Templates."
            : "\(count) hidden templates. Show them in Templates."
    }

    /// Create's template menu when every template of both sections is hidden.
    static let allHidden = "All templates are hidden. Show them in Templates."

    // MARK: Editor

    static let newTitle = "New template"
    static let editTitle = "Edit template"
    static let startFrom = "Start from"
    static let blank = "Blank"
    static let startFromFooter = "Change the starting point before you type; it replaces the fields."
    static let name = "Name"
    static let makes = "Makes"
    static let makesDocument = "A document"
    static let makesRewrite = "A rewrite"
    static let makesFooter =
        "A document is made from a whole recording or text, like a SOAP note. A rewrite turns text into a better "
        + "version of itself, like Polish."
    static let clinicalSwitch = "Makes clinical documents (patient information)"
    static let clinicalFooter =
        "What it makes is treated as patient information: it stays on this iPhone or a Mac you trust, and anything "
        + "else asks before each run. The item’s own privacy still applies."
    static let instructions = "Instructions"
    static let instructionsPlaceholder = "Use these headings, in this order…"
    static let instructionsHelp =
        "Tell the model what to write: the headings, their order, what goes under each, and what to leave out. "
        + "Parakeet adds the transcript after your instructions."
    static let placeholdersHelp =
        "{{userNotes}} is where your notes for the model go; {{transcript}} is where the transcript goes."
    static let save = "Save"
    static let cancel = "Cancel"
    static let saveAndTry = "Save and try…"
    static let saveAndTryHint = "Saves the template, then lets you choose a transcript to run it on."
    static let discardTitle = "Discard your changes?"
    static let discardMessage = "The template you typed is not saved."
    static let useThisText = "Use this text"
    static let useThisTextFooter =
        "Puts this version’s text in the editor. Save makes it a new version; this one stays as it is."
    static let current = "current"
    static let instructionsTitle = "Instructions"
    static let copy = "Copy"
    static let copied = "Copied"

    /// "12 of 40".
    static func nameCounter(_ count: Int) -> String {
        "\(count) of \(TemplateLimits.maxNameLength)"
    }

    /// "1,240 of 4,000 characters".
    static func instructionsCounter(_ count: Int) -> String {
        "\(grouped(count)) of \(grouped(TemplateLimits.maxInstructionCharacters)) characters"
    }

    /// "Earlier versions (2)".
    static func earlierVersions(_ count: Int) -> String { "Earlier versions (\(count))" }

    /// "Version 2 · 1 Oct 2026", with "· current" for the active one.
    static func versionRow(_ version: PromptVersion, isCurrent: Bool) -> String {
        let day = version.createdAt.formatted(date: .abbreviated, time: .omitted)
        return "Version \(version.versionNumber) · \(day)" + (isCurrent ? " · \(current)" : "")
    }

    /// "Clinic SOAP · version 2" for the read-only instructions sheet.
    static func instructionsSubtitle(name: String, version: Int?) -> String {
        version.map { "\(name) · version \($0)" } ?? name
    }

    // MARK: Document details

    static let templateNowRow = "Template now"
    static let showInstructionsUsed = "Show the instructions used"

    private static func grouped(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
