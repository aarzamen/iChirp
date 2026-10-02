import ChirpFeatures
import Foundation

/// The words on Capture's Record Meeting row for every meeting state (review R6a-2): it says "Recording" only while the
/// microphone is recording, and otherwise what the Meeting screen and the Live Activity say (Paused, Interrupted, the
/// microphone stopped and waits for Resume, Transcribing). Pure, so `CaptureMeetingRowTests` checks every state.
enum MeetingRowCopy {
    /// "Record Meeting", or "Meeting in progress" while one runs (from Start to its saved transcript or failure).
    static func title(for state: MeetingFlowState) -> String {
        state.isFinished ? "Record Meeting" : "Meeting in progress"
    }

    /// The line under the title. `seconds` is the recorded audio (it does not advance while paused);
    /// `finalPassProgress` the final pass's real fraction while transcribing.
    static func subtitle(for state: MeetingFlowState, seconds: TimeInterval, finalPassProgress: Double?) -> String {
        let time = Formatting.clock(ms: Int(seconds * 1000))
        switch state {
        case .idle, .saved, .failed: return "Transcribed on this iPhone"
        case .starting: return "Starting the microphone…"
        case .recording: return "Recording · \(time)"
        case .paused: return "Paused · \(time) · nothing is recorded"
        case .interrupted: return "Interrupted · \(time) · a call or Siri has the microphone"
        case .waitingForResume: return "Microphone stopped · \(time) · tap Return, then Resume"
        case .stopping:
            guard let finalPassProgress else { return "Transcribing on this iPhone" }
            return "Transcribing · \(Formatting.percent(finalPassProgress))%"
        }
    }

    /// The button's word: Start, or Return to the running meeting.
    static func button(for state: MeetingFlowState) -> String {
        state.isFinished ? "Start" : "Return"
    }

    /// VoiceOver's hint for the row.
    static func hint(for state: MeetingFlowState) -> String {
        switch state {
        case .idle, .saved, .failed: "Starts recording a meeting on this iPhone."
        case .starting: "Returns to the meeting that is starting."
        case .recording: "Returns to the meeting that is recording."
        case .paused: "Returns to the paused meeting. Nothing is recorded while it is paused."
        case .interrupted: "Returns to the meeting. Recording resumes when the call or Siri lets go of the microphone."
        case .waitingForResume: "Returns to the meeting. Nothing is recorded until you tap Resume."
        case .stopping: "Returns to the meeting while it is transcribed."
        }
    }
}
