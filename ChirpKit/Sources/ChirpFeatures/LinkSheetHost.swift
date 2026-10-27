import ChirpIngest
import Foundation
import Observation

/// What Parakeet does with a link shared to it (plan 029).
public enum SharedLinkStart: Sendable, Equatable {
    /// Paste a link starts on its own (the owner's own share, "Start shared links right away" on).
    case autoStart
    /// Paste a link opens with the link filled in and waits for Transcribe.
    case prefill
}

/// Plan 029: the Paste a link sheet across its presentations, so a shared link can open it from anywhere (cold launch,
/// after a recording, over another tab). It owns the sheet's one `LinkImportViewModel` (a fresh one each time the sheet
/// closes, as when the sheet made its own) and the one shared link that is waiting for the sheet to be free.
///
/// An idle, empty sheet takes a shared link at once. A sheet holding typed text, running, waiting at the companion
/// question or showing another link's result keeps its state; the shared link waits ("Shared link · Start") and starts
/// on its own when the sheet next finishes a run (if it was an auto-start), or when the person taps Start.
@MainActor @Observable public final class LinkSheetHost {
    public struct WaitingLink: Equatable, Sendable {
        public let link: URL
        public let start: SharedLinkStart
    }

    public var isPresented = false
    public private(set) var model: LinkImportViewModel
    public private(set) var waiting: WaitingLink?
    /// The sheet is on screen (between `sheetDidAppear()` and `sheetDidDismiss()`).
    public private(set) var isShowing = false
    /// A shared link that arrived while the sheet was not on screen yet: it is applied in `sheetDidAppear()`, so no
    /// network work starts unless the person can see the sheet (final review I2).
    @ObservationIgnored private var arriving: WaitingLink?

    @ObservationIgnored private let makeModel: @MainActor () -> LinkImportViewModel

    public init(makeModel: @escaping @MainActor () -> LinkImportViewModel) {
        self.makeModel = makeModel
        model = makeModel()
    }

    /// A shared link: shows the sheet; once the sheet is on screen it starts or fills it in when the sheet is free,
    /// otherwise it waits.
    public func deliver(_ link: URL, start: SharedLinkStart) {
        isPresented = true
        let incoming = WaitingLink(link: link, start: start)
        if isShowing { apply(incoming) } else { arriving = incoming }
    }

    /// The sheet is on screen: a link that arrived before it is applied now.
    public func sheetDidAppear() {
        isShowing = true
        if let arriving {
            self.arriving = nil
            apply(arriving)
        }
    }

    private func apply(_ incoming: WaitingLink) {
        // Final review I3: the link this sheet is already running (or just finished) is not run again.
        if !model.isIdleAndEmpty, model.isWorking || model.startedID != nil,
            Self.isSameLink(model.text, incoming.link.absoluteString)
        {
            return
        }
        if model.isIdleAndEmpty {
            waiting = nil
            model.start(link: incoming.link, autoStart: incoming.start == .autoStart)
        } else {
            waiting = incoming
        }
    }

    /// The sheet's state moved (its view calls this on every phase change): a waiting auto-start runs once the sheet
    /// has finished its own run (another link's result) or is empty again. Typed text and a failed or offered run are
    /// left for the person.
    public func modelDidChange() {
        guard let waiting, waiting.start == .autoStart else { return }
        if model.startedID != nil {
            model.reset()
        }
        guard model.isIdleAndEmpty else { return }
        self.waiting = nil
        model.start(link: waiting.link, autoStart: true)
    }

    /// The waiting row's Start: the person chose the shared link, so it replaces what the sheet held and starts.
    public func startWaiting() {
        guard let waiting else { return }
        self.waiting = nil
        if !model.isIdleAndEmpty { model.reset() }
        model.start(link: waiting.link, autoStart: true)
    }

    /// The same YouTube video in any link form, or the same link otherwise.
    static func isSameLink(_ first: String, _ second: String) -> Bool {
        switch (LinkClassifier.classify(first), LinkClassifier.classify(second)) {
        case (.youtube(let a, _), .youtube(let b, _)): return a == b
        default:
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
                == second.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The sheet closed: the next open gets a fresh sheet; a link still waiting is dropped with it. A started job is
    /// unaffected (it belongs to the Library).
    public func sheetDidDismiss() {
        isShowing = false
        waiting = nil
        arriving = nil
        model = makeModel()
    }
}
