import OSLog

/// Unified logging entry point. Every iChirp module logs under one subsystem so
/// `log stream --predicate 'subsystem == "com.aarzamen.ichirp"'` shows the whole app.
public enum Log {
    /// Returns a logger for `category` (for example "launch", "pipeline", "store").
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: "com.aarzamen.ichirp", category: category)
    }
}
