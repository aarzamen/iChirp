// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/Diarization/SpeakerAttributionResolver.swift
// (`fingerprint(for:)`, `FingerprintPayload`) @ bbae9e0e. Fresh implementation: words only (text and times), no
// speakers and no segments (segment ids are random per run; a speaker change does not move a word), versioned "w1:".

import CryptoKit
import Foundation

/// Identifies the engine's words a transcript's corrections were made against (plan 025, contract
/// `transcript-corrections-v1`). Corrections stay attached while a pipeline saves the same words again, and move to
/// `detached` when the words change (`TranscriptCorrections.preserved(acrossNewWords:now:)`).
public enum TranscriptFingerprint {
    /// `"w1:"` + lowercase hex SHA-256 over, for each word in order, `"\(startMs),\(endMs),\(utf8 count):\(word)\n"`.
    /// Speakers and confidences are not part of it.
    public static func of(_ words: [WordTimestamp]) -> String {
        var hasher = SHA256()
        for word in words {
            hasher.update(data: Data("\(word.startMs),\(word.endMs),\(word.word.utf8.count):\(word.word)\n".utf8))
        }
        return "w1:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
