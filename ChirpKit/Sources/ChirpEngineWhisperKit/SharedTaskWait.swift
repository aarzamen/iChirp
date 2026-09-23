// A copy of ChirpEngineFluidAudio's `SharedTaskWait.swift` (an engine target depends only on ChirpCore): the waiter of
// WhisperKit's shared model load gives up at once when it is cancelled (review I1).

import Foundation
import Synchronization

/// Awaits a task that several callers share (a model load), but gives up as soon as **this** caller is cancelled,
/// throwing `CancellationError`. The shared task keeps running for everyone else. (Awaiting `task.value` directly
/// ignores the caller's cancellation until the task ends: a cancelled dictation would sit through a whole load.)
func awaitSharedTask<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
    let gate = OneShotContinuation<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            Task {
                do {
                    gate.resume(with: .success(try await task.value))
                } catch {
                    gate.resume(with: .failure(error))
                }
            }
        }
    } onCancel: {
        gate.resume(with: .failure(CancellationError()))
    }
}

/// Resumes one continuation exactly once, whichever of `install` and the first `resume` comes first.
private final class OneShotContinuation<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}
