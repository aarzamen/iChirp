---
title: An in-order apply loop must publish a transient state (a drop, a lagging flag) when it applies, not only at the end of the pass
date: 2026-09-23
category: concurrency
module: ChirpFeatures
problem_type: test_failure
component: MeetingLiveTranscriber
severity: medium
applies_when:
  - "testBackpressureDropsMarkThePreviewLaggingAndFinishCancelsPendingChunks ... XCTAssertTrue failed - a dropped chunk marks the preview lagging"
  - A test passes 50 of 50 alone and fails now and then in the full suite
  - Results are buffered by sequence number and applied "while the next one is here", then one update is published
resolution_type: code_fix
tags: [swift-concurrency, ordering, actor, sequence-buffer, flaky-test, meeting, live-preview, backpressure]
---

# An in-order apply loop must publish transient state when it applies

## Context
`MeetingLiveTranscriberTests.testBackpressureDropsMarkThePreviewLaggingAndFinishCancelsPendingChunks` failed once in a
full-suite run and once in 5 isolated runs, always at the `all.contains { $0.isLagging }` assertion.

## Problem
A 50-run sequential `swift test --filter` loop never failed. Running the test binary directly from 24 parallel
workers did (50 of 960 runs):

```bash
swift build --build-tests --package-path ChirpKit
BIN=ChirpKit/.build/debug/ChirpKitPackageTests.xctest
T=ChirpFeaturesTests.MeetingLiveTranscriberTests/testBackpressureDropsMarkThePreviewLaggingAndFinishCancelsPendingChunks
for w in $(seq 1 24); do (for i in $(seq 1 40); do xcrun xctest -XCTest "$T" "$BIN" >/dev/null 2>&1 || echo FAIL; done) & done; wait
```

(`swift test` takes a lock on `.build`, so parallel `swift test` runs queue one behind another. Call `xctest` directly
instead.) A temporary `print` in `complete(_:_:)` showed every failure recorded outcomes in the order 1 (drop),
2 (result), 0 (result). Passing runs recorded 1, 0, 2.

## Solution
In `MeetingLiveTranscriber.complete(_:_:)`, publish the update as soon as a drop applies (when the flag turns on),
before a later result in the same pass can clear it; results still publish once at the end of the pass. The
deterministic test `testADropAppliedInTheSamePassAsALaterResultIsStillPublishedAsLagging` calls the (now internal)
`complete` with outcomes in the order 1, 2, 0.

## Why this works
A chunk task records its outcome only after `SpeechJobScheduler.run` has returned, and by then the slot is already
released and the next chunk dispatched. So chunk 3 can transcribe and report before chunk 1's task hops back to the
actor. The sequence buffer keeps the *text* in order, but the loop applied result, drop, result in one pass and
published only the final state (`isLagging == false`). The drop never reached the stream. Publishing when the flag
turns on makes the stream the same for every arrival order.

## Prevention
- When a sequence buffer applies several items in one pass, ask which intermediate states must be observable, and
  publish those as they apply.
- Don't assume "the scheduler runs jobs in order, so their completions reach me in order". A report sent after the
  slot is released is an independent hop.
- If a sequential loop won't reproduce a flake, run `xctest` from many parallel workers before you conclude it's
  timing noise. Add a temporary print to capture the arrival order, then pin that order in a deterministic test.
