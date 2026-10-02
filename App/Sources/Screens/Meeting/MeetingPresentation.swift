import ChirpFeatures
import SwiftUI

/// The Meeting screen over everything while a meeting runs (unless the person chose "Hide recording"). It lives in its
/// own overlay window (`RootOverlayWindows`, review R6a-4), so it appears even over a sheet a tab screen has open.
struct MeetingCoverLayer: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: isMeetingShown) {
                MeetingCover()
                    .environment(environment)
            }
            .onChange(of: environment.meeting.state) { _, state in
                // R6a-2: a final pass that fails while the screen is hidden brings it back, with the error and Retry,
                // instead of Capture's row quietly turning back into "Record Meeting".
                if case .failed(_, let id) = state, id != nil, environment.meeting.isScreenHidden {
                    environment.meeting.isScreenHidden = false
                }
            }
    }

    /// Shown from Start until the person closes it; "Hide recording" hides it while recording continues.
    private var isMeetingShown: Binding<Bool> {
        Binding(
            get: {
                Self.isShown(
                    state: environment.meeting.state, isScreenHidden: environment.meeting.isScreenHidden,
                    dictationState: environment.dictation.state)
            },
            set: { presented in
                guard !presented else { return }
                if environment.meeting.state.isFinished {
                    environment.meeting.dismiss()
                } else {
                    environment.meeting.isScreenHidden = true
                }
            })
    }

    /// Whether the Meeting screen shows. A dictation started during a meeting (Action Button) takes the screen; the
    /// meeting keeps recording and Capture's "Return" brings it back.
    static func isShown(state: MeetingFlowState, isScreenHidden: Bool, dictationState: DictationFlowState) -> Bool {
        let dictating = dictationState != .idle && dictationState != .cancelled
        return state != .idle && !isScreenHidden && !dictating
    }
}

/// The launch recovery sheet when an earlier launch left meetings behind (and the Library banner reopens it). It stays
/// on the app's own window: it opens at launch, before anything else is up, or from the Library.
struct MeetingRecoveryPresentation: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        @Bindable var environment = environment
        content
            .sheet(isPresented: $environment.isMeetingRecoveryPresented) {
                MeetingRecoverySheet()
                    .environment(environment)
            }
    }
}

/// The Meeting screen in its own navigation stack, so a saved meeting opens its transcript right here.
private struct MeetingCover: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            MeetingScreen(openTranscript: { path = [$0] })
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { id in
                    TranscriptScreen(id: id)
                }
        }
        .onChange(of: environment.meeting.state) { _, state in
            // Stop & save → Transcript (handoff): open it the moment it is saved.
            if case .saved(let id) = state { path = [id] }
        }
    }
}

extension View {
    /// The M3 launch recovery sheet.
    func meetingRecoveryPresentation() -> some View {
        modifier(MeetingRecoveryPresentation())
    }
}
