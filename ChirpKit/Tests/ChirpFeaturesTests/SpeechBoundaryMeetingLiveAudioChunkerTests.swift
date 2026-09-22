// Ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/Audio/SpeechBoundaryMeetingLiveAudioChunkerTests.swift @ bbae9e0e
// Changes: the scripted VAD is a `ChirpCore.VoiceActivityStream`; test names kept. `testResetRestartsTimelineAtZero`
// is not ported (iChirp builds a new chunker per meeting, so there is no reset). Plus the fixed chunker.

import ChirpCore
import XCTest

@testable import ChirpFeatures

final class SpeechBoundaryMeetingLiveAudioChunkerTests: XCTestCase {
    private let window = 4_096
    private let maxChunkSamples = 160_000

    func testSpeechEndAfterMinimumEmitsOneContiguousChunk() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(events: [1: .speechStart, 10: .speechEnd(sampleIndex: 40_960)]))
        let chunks = await feed(chunker, windows: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 40_960)
        XCTAssertEqual(chunks[0].startMs, 0)
        XCTAssertEqual(chunks[0].endMs, 2_560)
    }

    func testSubMinimumSpeechEndIsNotEmittedButExtendedByNextEnd() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(events: [
                1: .speechStart, 4: .speechEnd(sampleIndex: 16_000), 10: .speechEnd(sampleIndex: 40_960),
            ]))
        let chunks = await feed(chunker, windows: 10)
        XCTAssertEqual(chunks.count, 1, "sub-minimum end must not emit on its own")
        XCTAssertEqual(chunks[0].samples.count, 40_960)
        XCTAssertEqual(chunks[0].startMs, 0)
    }

    func testConsecutiveSpeechEndsAreContiguous() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(events: [
                1: .speechStart, 10: .speechEnd(sampleIndex: 40_960), 11: .speechStart,
                20: .speechEnd(sampleIndex: 81_920),
            ]))
        let chunks = await feed(chunker, windows: 20)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].endMs, 2_560)
        XCTAssertEqual(chunks[1].startMs, chunks[0].endMs)
        XCTAssertEqual(chunks[1].endMs, 5_120)
    }

    func testSilenceOnlyInputEmitsNothing() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream())
        let chunks = await feed(chunker, windows: 6)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testProlongedSilenceIsDiscardedNotEmitted() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream())
        let chunks = await feed(chunker, windows: 45)
        XCTAssertTrue(chunks.isEmpty, "silence must never be emitted as a chunk")
        let diag = await chunker.diagnostics
        XCTAssertGreaterThanOrEqual(diag.droppedSilenceWindows, 1)
        XCTAssertEqual(diag.forceEmits, 0)
    }

    func testForceEmitAtMaxDurationKeepsTailOverlap() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream(events: [1: .speechStart]))
        let chunks = await feed(chunker, windows: 40)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, maxChunkSamples)
        XCTAssertEqual(chunks[0].endMs, 10_000)
        let diag = await chunker.diagnostics
        XCTAssertEqual(diag.forceEmits, 1)
        let more = await feed(chunker, windows: 40)
        let next = try? XCTUnwrap(more.first, "expected a second force-emit")
        XCTAssertEqual(next?.startMs, (maxChunkSamples - 4_000) * 1000 / 16_000, "0.25 s of overlap re-fed")
    }

    func testFlushEmitsSpokenTail() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream(events: [1: .speechStart]))
        _ = await feed(chunker, windows: 5)
        let tail = await chunker.flush()
        XCTAssertEqual(tail?.samples.count, 20_480)
        XCTAssertEqual(tail?.startMs, 0)
        XCTAssertEqual(tail?.endMs, 1_280)
    }

    func testFlushDropsSilentTail() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream())
        _ = await feed(chunker, windows: 5)
        let tail = await chunker.flush()
        XCTAssertNil(tail, "a tail with no detected speech must be dropped")
    }

    func testFlushDropsTinyTail() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream(events: [1: .speechStart]))
        _ = await feed(chunker, windows: 1)
        let tail = await chunker.flush()
        XCTAssertNil(tail, "a sub-0.5s tail must be dropped")
    }

    func testRepeatedVADErrorsFallBackToFixedChunking() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream(failCalls: [1, 2, 3]))
        let chunks = await feed(chunker, windows: 25)
        let diag = await chunker.diagnostics
        XCTAssertTrue(diag.fellBackToFixed)
        XCTAssertGreaterThanOrEqual(diag.vadErrors, 3)
        XCTAssertEqual(chunks.first?.samples.count, 80_000)
        XCTAssertEqual(chunks.first?.startMs, 0)
        XCTAssertEqual(chunks.first?.endMs, 5_000)
        for (lhs, rhs) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(lhs.startMs, rhs.startMs)
        }
    }

    func testTransientVADErrorDoesNotTriggerFallback() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(
                events: [1: .speechStart, 10: .speechEnd(sampleIndex: 40_960)], failCalls: [2]))
        let chunks = await feed(chunker, windows: 10)
        let diag = await chunker.diagnostics
        XCTAssertFalse(diag.fellBackToFixed)
        XCTAssertEqual(diag.vadErrors, 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.samples.count, 40_960)
    }

    func testLargeSingleIngestDropsLeadingSilenceButKeepsLaterSpeech() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(vad: FakeVoiceActivityStream(events: [41: .speechStart]))
        let emitted = await chunker.addSamples([Float](repeating: 0.1, count: 45 * window))
        XCTAssertTrue(emitted.isEmpty)
        let tail = await chunker.flush()
        XCTAssertEqual(tail?.samples.count, 24_576, "speech audio must survive the silence drop")
        XCTAssertEqual(tail?.startMs, 9_984)
        XCTAssertEqual(tail?.endMs, 11_520)
    }

    func testStaleRetroactiveSpeechEndDropsTrailingSilenceInsteadOfForcing() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(events: [1: .speechStart, 41: .speechEnd(sampleIndex: 150_000)]))
        let chunks = await feed(chunker, windows: 78)
        XCTAssertEqual(chunks.count, 1, "only the single force-emit should be emitted")
        let diag = await chunker.diagnostics
        XCTAssertEqual(diag.forceEmits, 1)
        XCTAssertGreaterThanOrEqual(diag.droppedSilenceWindows, 1)
    }

    func testFlushTrimsTrailingSilenceAtSpeechEndBoundary() async {
        let chunker = SpeechBoundaryMeetingLiveAudioChunker(
            vad: FakeVoiceActivityStream(events: [1: .speechStart, 11: .speechEnd(sampleIndex: 40_960)]))
        let emitted = await chunker.addSamples([Float](repeating: 0.1, count: 10 * window + 2_000))
        XCTAssertTrue(emitted.isEmpty)
        let tail = await chunker.flush()
        XCTAssertEqual(tail?.samples.count, 40_960, "trailing silence past the speech-end must be trimmed")
        XCTAssertEqual(tail?.endMs, 2_560)
    }

    // MARK: - Fixed chunker (upstream AudioChunker)

    func testFixedChunkerCutsFiveSecondWindowsWithOneSecondOverlapAndFlushesTheTail() async {
        let chunker = FixedMeetingLiveAudioChunker()
        let chunks = await chunker.addSamples([Float](repeating: 0.1, count: 12 * 16_000))
        XCTAssertEqual(chunks.map(\.startMs), [0, 4_000])
        XCTAssertEqual(chunks.map(\.endMs), [5_000, 9_000])
        let tail = await chunker.flush()
        XCTAssertEqual(tail?.startMs, 8_000)
        XCTAssertEqual(tail?.endMs, 12_000)
        let tiny = FixedMeetingLiveAudioChunker()
        _ = await tiny.addSamples([Float](repeating: 0.1, count: 7_000))
        let dropped = await tiny.flush()
        XCTAssertNil(dropped, "under 0.5 s is not flushed")
    }

    @discardableResult
    private func feed(_ chunker: SpeechBoundaryMeetingLiveAudioChunker, windows: Int) async -> [MeetingAudioChunk] {
        var all: [MeetingAudioChunk] = []
        for _ in 0..<windows {
            all += await chunker.addSamples([Float](repeating: 0.1, count: window))
        }
        return all
    }
}
