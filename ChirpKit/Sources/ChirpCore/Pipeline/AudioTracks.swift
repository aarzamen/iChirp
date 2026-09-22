// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Audio/AudioTrackDescriptor.swift @ bbae9e0e — the
// zero-based ordinal among audio tracks, its one-based "Track N" label and the language/default suffixes. Fresh
// implementation over AVFoundation track metadata (no FFmpeg stream index), not a line port.

import Foundation

/// One audio track inside a media file (M1.5 audio-track selection,
/// `spec/contracts/file-transcription-audio-tracks-v1.md`).
///
/// `ordinal` is zero-based **among audio tracks only**, in the order AVFoundation lists them; it is what is stored in
/// `Transcription.audioTrackOrdinal` and passed to `AudioNormalizing.normalize(…audioTrackOrdinal:)`. People see it
/// one-based ("Track 2"). `trackID` is the container's own id: informational, never used to select a track.
public struct AudioTrackDescriptor: Identifiable, Sendable, Equatable {
    public let ordinal: Int
    public let trackID: Int?
    /// ISO 639 code from the file ("eng", "es"), or nil when absent or undetermined.
    public let languageCode: String?
    /// The track the file marks as the one to play (only meaningful when the file also has tracks it does not mark).
    public let isDefault: Bool

    public var id: Int { ordinal }
    /// The one-based number people see.
    public var number: Int { ordinal + 1 }

    public init(ordinal: Int, trackID: Int? = nil, languageCode: String? = nil, isDefault: Bool = false) {
        self.ordinal = ordinal
        self.trackID = trackID
        self.languageCode = languageCode
        self.isDefault = isDefault
    }

    /// "Track 2", plus " — English" when the file names a language and " (Default)" for its default track. Always
    /// has the numbered fallback, whatever the metadata says.
    public var displayName: String {
        var label = "Track \(number)"
        if let languageName {
            label += " — \(languageName)"
        }
        if isDefault {
            label += " (Default)"
        }
        return label
    }

    private var languageName: String? {
        guard let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
            code.lowercased() != "und"
        else {
            return nil
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

/// Lists a media file's audio tracks without decoding them (AVFoundation metadata in the app; a fake in tests).
public protocol AudioTrackProbing: Sendable {
    /// The file's audio tracks in ordinal order; empty when it has none.
    func audioTracks(in sourceURL: URL) async throws -> [AudioTrackDescriptor]
}

/// Why an explicit audio-track choice could not be used. The job fails with this message; it never falls back to
/// another track.
public enum AudioTrackSelectionError: Error, Equatable, LocalizedError {
    /// The file has no audio track with this zero-based ordinal (for example a batch choice a later file lacks).
    case trackMissing(ordinal: Int, trackCount: Int)
    /// This normalizer cannot choose a track.
    case selectionUnsupported

    public var errorDescription: String? {
        switch self {
        case .trackMissing(let ordinal, let trackCount):
            let has = trackCount == 1 ? "1 audio track" : "\(trackCount) audio tracks"
            return "This file has no audio track \(ordinal + 1) (it has \(has)). Import it again and choose a track "
                + "it has."
        case .selectionUnsupported:
            return "This build cannot choose an audio track inside a file."
        }
    }
}
