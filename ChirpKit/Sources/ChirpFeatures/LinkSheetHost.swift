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

    @ObservationIgnored private let makeModel: @MainActor () -> LinkImportViewModel

    public init(makeModel: @escaping @MainActor () -> LinkImportViewModel) {
        self.makeModel = makeModel
        model = makeModel()
    }

    /// A shared link: shows the sheet; starts or fills it in now when the sheet is free, otherwise it waits.
    public func deliver(_ link: URL, start: SharedLinkStart) {
        isPresented = true
        if model.isIdleAndEmpty {
            waiting = nil
            model.start(link: link, autoStart: start == .autoStart)
        } else {
            waiting = WaitingLink(link: link, start: start)
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

    /// The sheet closed: the next open gets a fresh sheet; a link still waiting is dropped with it. A started job is
    /// unaffected (it belongs to the Library).
    public func sheetDidDismiss() {
        waiting = nil
        model = makeModel()
    }
}
