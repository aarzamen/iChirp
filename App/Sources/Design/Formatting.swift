import ChirpCore
import ChirpFeatures
import Foundation

/// Display strings shared by the screens. Pure functions, covered by `FormattingTests`.
enum Formatting {
    /// Player and timestamp style, zero-padded: "00:06", "03:41", "1:02:03".
    static func clock(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(seconds)
        }
        return twoDigits(minutes) + ":" + twoDigits(seconds)
    }

    /// Meta-line style, as on the canvas: "0:12", "28:40", "1:02:03".
    static func duration(ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(seconds)
        }
        return "\(minutes):" + twoDigits(seconds)
    }

    /// "1 speaker", "4 speakers".
    static func speakers(_ count: Int) -> String {
        count == 1 ? "1 speaker" : "\(count) speakers"
    }

    /// Whole percent of a 0…1 fraction, clamped: 0.623 → 62.
    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }

    /// Size on disk: "480 MB", "1.2 GB".
    static func size(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1000 {
            return String(format: "%.1f GB", megabytes / 1000)
        }
        return "\(Int(megabytes.rounded())) MB"
    }

    /// "Today", "Yesterday", else "Sep 19".
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone
        )
        .month(.abbreviated).day()
        return date.formatted(style)
    }

    /// "2:34 PM" in the user's locale.
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The kind word on a row's meta line.
    static func kind(_ sourceType: Transcription.SourceType) -> String {
        switch sourceType {
        case .file: "File"
        case .dictation: "Dictation"
        case .meeting: "Meeting"
        case .url: "Video"
        case .podcast: "Podcast"
        case .document: "Document"
        }
    }

    /// A finished row's meta line: "File · 0:06 · 2 speakers", "Dictation · 0:12 · 2:34 PM".
    static func meta(for item: Transcription) -> String {
        var parts = [kind(item.sourceType)]
        if let durationMs = item.durationMs, durationMs > 0 {
            parts.append(duration(ms: durationMs))
        }
        if let count = item.speakerCount, count > 0 {
            parts.append(speakers(count))
        } else if item.sourceType == .dictation {
            parts.append(timeOfDay(item.createdAt))
        }
        return parts.joined(separator: " · ")
    }

    /// The Transcript header's meta line: "Today · 0:06 · 2 speakers".
    static func transcriptMeta(for item: Transcription, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts = [day(item.createdAt, now: now, calendar: calendar)]
        if let durationMs = item.durationMs, durationMs > 0 {
            parts.append(duration(ms: durationMs))
        }
        if let count = item.speakerCount, count > 0 {
            parts.append(speakers(count))
        }
        return parts.joined(separator: " · ")
    }

    /// A running job's line: "Transcribing · 62%", "Identifying speakers · 90%".
    static func progress(_ progress: JobProgress) -> String {
        "\(progress.stage.displayName) · \(percent(progress.fraction))%"
    }

    /// The line a row shows for a status that is not `.completed`, or nil for completed rows.
    static func statusLine(for item: Transcription, progress: JobProgress?) -> String? {
        switch item.status {
        case .completed:
            return nil
        case .processing:
            return progress.map(Self.progress) ?? "Waiting to start"
        case .failed:
            let message = item.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? "Transcription failed" : message
        case .interrupted:
            return "Interrupted — Parakeet closed before it finished"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Whether a row in this status offers Retry.
    static func canRetry(_ status: Transcription.Status) -> Bool {
        status == .failed || status == .interrupted || status == .cancelled
    }

    /// A readable message for any error.
    static func message(for error: any Error) -> String {
        if let exportError = error as? ExportErrorDescribing {
            return exportError.readableMessage
        }
        if let description = (error as? any LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// Errors from modules whose error types carry no user-facing text.
protocol ExportErrorDescribing {
    var readableMessage: String { get }
}
