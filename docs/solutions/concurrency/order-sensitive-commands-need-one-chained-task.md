---
title: Send order-sensitive commands (pause, resume, mute) through one chained task, never one fire-and-forget Task each
date: 2026-09-22
category: concurrency
module: ChirpFeatures
problem_type: test_failure
component: MeetingCoordinator
severity: high
applies_when:
  - "testPauseMuteAndInterruptionsReachTheRecorderAndDriveTheState ... failed - condition not met"
  - A test that sends several commands to an actor-backed service passes alone but fails only in the full suite
  - A coordinator does `Task { await service.doA() }` then `Task { await service.doB() }` and B must follow A
resolution_type: code_fix
tags: [swift-concurrency, task-ordering, actor, fire-and-forget, flaky-test, meeting, recorder]
---

# Order-sensitive commands need one chained task

## Context
Merging the wave-1 and wave-2 lanes of plan 018 and running the full `swift test` gate after each merge.

## Problem
`MeetingCoordinatorTests.testPauseMuteAndInterruptionsReachTheRecorderAndDriveTheState` passed on its own every time
and failed only in full `swift test` runs: the fake recorder had not received `paused == [true, false]`. Making the
wait longer (a time bound instead of a yield count) did not help; it failed again after 5 s.

## Solution
Keep the last command's task and make each new command await it:

```swift
private var recorderCommandTail: Task<Void, Never>?

private func sendToRecorder(_ command: @escaping @Sendable () async -> Void) {
    let previous = recorderCommandTail
    recorderCommandTail = Task {
        await previous?.value
        await command()
    }
}
```

Flows that end the session (`stop`, `discard`) capture the tail and await it before they start. AGENTS.md already says
"when ordering or a result matters, make the API async and await it instead of using fire-and-forget `Task`"; where
the caller is a synchronous UI action, the chained task is the way to honor it.

## Why this works
`MeetingCoordinator.pause()`, `resume()` and `toggleMute()` each started an independent `Task { await
recorder.setPaused(…) }`. Separate tasks carry no ordering guarantee, and a slow or suspended first command lets a
later one overtake it. In the app that means a quick Pause → Resume could reach the recorder as resume-then-pause:
the recorder ends paused while the screen says Recording, and the meeting silently stops capturing audio.

A deterministic test proves it: hold the first `setPaused(true)` inside the fake (a continuation), call `resume()`,
and the `false` arrives first (`testRecorderCommandsKeepTheirOrderWhenOneIsSlow`).

The chain turns "whichever task runs first" into "each command starts after the previous one finished".

## Prevention
- Any coordinator method that fires a command at an actor-backed service where order matters goes through one chain
  (or an `AsyncStream` consumed by one task).
- Test ordering with a fake that can hold one call open, not with timing.
