import Foundation

/// Shared ISO 8601 formatting for tool output. We use the Swift 5.5+
/// `FormatStyle` API which is `Sendable` and cheaper than
/// `ISO8601DateFormatter` (which isn't Sendable, so Swift 6 strict
/// concurrency makes it annoying to cache).
///
/// Style choices:
/// - Output: internet datetime with UTC (e.g. `2026-04-21T10:00:00Z`).
/// - Parse: accept fractional seconds, plain internet datetime, or
///   bare date (`YYYY-MM-DD`). Callers pass ISO strings through many
///   layers; being permissive here is worth the small complexity.
public enum ISODate {
    /// Format a Date as ISO 8601 internet datetime in UTC.
    public static func string(from date: Date) -> String {
        date.formatted(
            .iso8601
                .year().month().day()
                .dateTimeSeparator(.standard)
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .omitted)
        )
    }

    /// Parse an ISO string into a Date. Tries, in order:
    ///   1. Full ISO 8601 datetime with fractional seconds, e.g. `2026-04-21T10:00:00.500Z`.
    ///   2. Full ISO 8601 datetime without fractional seconds, e.g. `2026-04-21T10:00:00Z`.
    ///   3. Bare date in local time, e.g. `2026-04-21`.
    ///
    /// The fractional-seconds strategy comes first because `.iso8601`'s
    /// default behavior around fractional seconds has drifted between
    /// macOS versions — being explicit about both shapes avoids that
    /// surprise.
    ///
    /// - Returns: The parsed date, or `nil` when the string matches none.
    public static func parse(_ s: String) -> Date? {
        let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? Date(s, strategy: withFractional) {
            return d
        }
        if let d = try? Date(s, strategy: .iso8601) {
            return d
        }
        // Fallback for bare `YYYY-MM-DD` — `.iso8601` requires a time part.
        let dateOnly = Date.ISO8601FormatStyle(
            dateSeparator: .dash, dateTimeSeparator: .standard,
            timeZone: .current
        ).year().month().day()
        if let d = try? Date(s, strategy: dateOnly) {
            return d
        }
        return nil
    }
}
