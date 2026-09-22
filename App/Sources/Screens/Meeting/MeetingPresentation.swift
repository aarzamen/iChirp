import ChirpFeatures
import SwiftUI

/// Presents the Meeting screen over the tabs while a meeting runs (unless the person chose "Hide recording"), and the
/// recovery sheet at launch when an earlier launch left meetings behind. `RootTabView` applies it with one line.
struct MeetingPresentation: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        @Bindable var environment = environment
        content
            .fullScreenCover(isPresented: isMeetingShown) {
                MeetingCover()
                    .environment(environment)
            }
            .sheet(isPresented: $environment.isMeetingRecoveryPresented) {
                MeetingRecoverySheet()
                    .environment(environment)
            }
    }

    /// Shown from Start until the person closes it; "Hide recording" hides it while recording continues.
    private var isMeetingShown: Binding<Bool> {
        Binding(
            get: {
                // A dictation started during a meeting (Action Button) takes the screen; the meeting keeps
                // recording and Capture's "Return" brings it back.
                let dictating = environment.dictation.state != .idle && environment.dictation.state != .cancelled
                return environment.meeting.state != .idle && !environment.meeting.isScreenHidden && !dictating
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
                    TranscriptScreen(id: id, environment: environment)
                }
        }
        .onChange(of: environment.meeting.state) { _, state in
            // Stop & save → Transcript (handoff): open it the moment it is saved.
            if case .saved(let id) = state { path = [id] }
        }
    }
}

extension View {
    /// The M3 meeting cover and the launch recovery sheet.
    func meetingPresentation() -> some View {
        modifier(MeetingPresentation())
    }
}
