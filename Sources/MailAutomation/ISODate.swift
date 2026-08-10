import Foundation

/// Shared ISO 8601 handling.
///
/// Output uses the Swift 5.5+ `FormatStyle` API which is `Sendable` and
/// cheaper than `ISO8601DateFormatter` (which isn't Sendable, so Swift 6
/// strict concurrency makes it annoying to cache).
///
/// Parsing is hand-rolled rather than delegated to `ISO8601FormatStyle`.
/// The previous implementation tried two datetime strategies and then fell
/// back to a *bare-date* strategy, and `Date.ISO8601FormatStyle` will
/// happily consume only the leading `YYYY-MM-DD` of a longer string. So a
/// timestamp with no timezone designator — `2026-08-18T16:30:00`, rejected
/// by both datetime strategies — reached the bare-date fallback and parsed
/// *successfully* as local midnight, silently discarding the time. A
/// successful-but-wrong parse is worse than a failed one: it pushes a
/// nonsense value downstream where the eventual complaint has nothing to do
/// with the real problem.
///
/// The rules now:
/// - A trailing `Z`/`z` or `±HH[:MM]` designator fixes the instant.
/// - Without a designator the timestamp is *floating*: it means that wall
///   clock in `timeZone`. It is never silently assumed to be UTC, which
///   would shift the value by the zone's offset.
/// - A bare `YYYY-MM-DD` is midnight in the same zone.
/// - Anything not fully consumed is a parse failure. No partial parses.
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

    /// Parse an ISO 8601 string, resolving offset-less ("floating")
    /// timestamps against `timeZone`. Accepted shapes:
    ///
    ///   2026-08-18                     bare date  → midnight in `timeZone`
    ///   2026-08-18T16:30               floating   → 16:30 in `timeZone`
    ///   2026-08-18T16:30:00            floating
    ///   2026-08-18T16:30:00.500        floating, fractional seconds
    ///   2026-08-18T16:30:00-04:00      explicit offset (also -0400, -04)
    ///   2026-08-18T20:30:00Z           UTC
    ///
    /// - Returns: The parsed date, or `nil` when the string isn't one of
    ///   those — including when it only *starts* like one.
    public static func parse(_ s: String, timeZone: TimeZone) -> Date? {
        var sc = Cursor(s.trimmingCharacters(in: .whitespaces))

        guard let year = sc.digits(4), sc.match("-"),
              let month = sc.digits(2), sc.match("-"),
              let day = sc.digits(2)
        else { return nil }

        var hour = 0, minute = 0, second = 0
        var fraction: TimeInterval = 0
        if sc.matchAny("T", "t", " ") != nil {
            guard let h = sc.digits(2), sc.match(":"), let m = sc.digits(2) else { return nil }
            hour = h
            minute = m
            if sc.match(":") {
                guard let s = sc.digits(2) else { return nil }
                second = s
                if sc.matchAny(".", ",") != nil {
                    guard let f = sc.fraction() else { return nil }
                    fraction = f
                }
            }
        }

        // Timezone designator. Absent → floating, resolved in `timeZone`.
        var zone = timeZone
        if sc.matchAny("Z", "z") != nil {
            zone = TimeZone(secondsFromGMT: 0)!
        } else if let sign = sc.matchAny("+", "-") {
            guard let offsetHours = sc.digits(2) else { return nil }
            var offsetMinutes = 0
            if sc.match(":") {
                guard let m = sc.digits(2) else { return nil }
                offsetMinutes = m
            } else if let m = sc.digits(2) {
                offsetMinutes = m
            }
            guard offsetHours <= 23, offsetMinutes <= 59 else { return nil }
            let seconds = (offsetHours * 3600 + offsetMinutes * 60) * (sign == "-" ? -1 : 1)
            guard let z = TimeZone(secondsFromGMT: seconds) else { return nil }
            zone = z
        }

        // The whole string must have been consumed — this is what stops a
        // datetime from being read as just its date half.
        guard sc.atEnd else { return nil }

        guard (1 ... 12).contains(month), day >= 1, day <= Self.daysInMonth(month, year),
              hour <= 23, minute <= 59, second <= 60
        else { return nil }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        // Calendar handles DST for us: an ambiguous wall clock (fall-back
        // hour) resolves to its first occurrence, and a nonexistent one
        // (spring-forward gap) shifts forward.
        guard let base = cal.date(from: comps) else { return nil }
        return fraction == 0 ? base : base.addingTimeInterval(fraction)
    }

    /// Parse resolving offset-less timestamps in the system zone.
    ///
    /// A distinct overload rather than a defaulted parameter on
    /// ``parse(_:timeZone:)``: a defaulted parameter would stop `parse`
    /// being usable as a `(String) -> Date?` function value, silently
    /// breaking `.map(ISODate.parse)` / `.flatMap(ISODate.parse)` at
    /// existing call sites.
    public static func parse(_ s: String) -> Date? {
        parse(s, timeZone: .current)
    }

    private static func daysInMonth(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        default: 0
        }
    }

    /// Minimal forward-only character cursor. Deliberately dumb: every
    /// accessor either consumes exactly what it matched or consumes
    /// nothing, so `atEnd` is a trustworthy "fully parsed" check.
    private struct Cursor {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        var atEnd: Bool { i >= chars.count }

        mutating func digits(_ n: Int) -> Int? {
            guard i + n <= chars.count else { return nil }
            var value = 0
            for k in i ..< (i + n) {
                guard chars[k].isASCII, let d = chars[k].wholeNumberValue, (0 ... 9).contains(d)
                else { return nil }
                value = value * 10 + d
            }
            i += n
            return value
        }

        mutating func match(_ c: Character) -> Bool {
            guard !atEnd, chars[i] == c else { return false }
            i += 1
            return true
        }

        mutating func matchAny(_ candidates: Character...) -> Character? {
            guard !atEnd, candidates.contains(chars[i]) else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        /// One or more digits after a `.`/`,`, as a sub-second interval.
        mutating func fraction() -> TimeInterval? {
            let start = i
            while !atEnd, chars[i].isASCII, chars[i].isNumber {
                i += 1
            }
            guard i > start else { return nil }
            return TimeInterval("0." + String(chars[start ..< i]))
        }
    }
}
