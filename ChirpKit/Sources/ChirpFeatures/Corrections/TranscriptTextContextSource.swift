// New for iChirp (plan 025 R6): the person's clean-up rules as the one accessor needs them.

import ChirpCore
import ChirpText
import Foundation

extension TranscriptTextContext {
    /// The rules a Clean view of a corrected transcript runs, from the person's Settings: the manual, enabled custom
    /// words (learned rules act only as corrections, plan 025 D8), the enabled snippets (the accessor applies them to
    /// dictation rows only) and the "remove um" setting. Rules that cannot be read count as none, as clean-up does.
    public static func current(textRules: any TextRulesStoring, settings: any SettingsStoring) async
        -> TranscriptTextContext
    {
        let rules = await DictationTextRules.enabled(in: textRules)
        return TranscriptTextContext(
            customWords: rules.customWords.filter { $0.isEnabled && $0.source == .manual },
            snippets: rules.snippets.filter(\.isEnabled),
            removeUmFiller: settings.load().removeUmFiller)
    }

    /// `current(textRules:settings:)` as the provider the services and view models take.
    public static func provider(textRules: any TextRulesStoring, settings: any SettingsStoring)
        -> @Sendable () async -> TranscriptTextContext
    {
        { await current(textRules: textRules, settings: settings) }
    }
}
