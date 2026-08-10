import Foundation
@testable import MailAutomation
import Testing

@Suite("ISODate")
struct ISODateTests {
    private let eastern = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    /// Wall-clock components of `date` as seen from `zone`.
    private func wall(_ date: Date, in zone: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    @Test("round-trips a UTC date through string→parse")
    func roundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_745_230_200) // 2026-04-21T10:50:00Z
        let s = ISODate.string(from: original)
        let parsed = try #require(ISODate.parse(s))
        #expect(abs(parsed.timeIntervalSince(original)) < 1)
    }

    // MARK: - offset-less input

    /// Regression: an offset-less datetime used to reach the bare-date
    /// fallback and parse as local **midnight**, silently dropping the
    /// time. Two different timestamps on the same day came out equal.
    @Test("offset-less datetime keeps its time rather than collapsing to midnight")
    func offsetLessKeepsWallClock() throws {
        let morning = try #require(ISODate.parse("2026-08-18T16:30:00", timeZone: eastern))
        let evening = try #require(ISODate.parse("2026-08-18T18:00:00", timeZone: eastern))

        let w = wall(morning, in: eastern)
        #expect(w.year == 2026 && w.month == 8 && w.day == 18)
        #expect(w.hour == 16 && w.minute == 30 && w.second == 0)

        // The bug's signature: these used to be the same instant.
        #expect(evening > morning)
        #expect(evening.timeIntervalSince(morning) == 90 * 60)
    }

    @Test("offset-less input is read as local wall clock, never as UTC")
    func offsetLessIsNotUTC() throws {
        let floating = try #require(ISODate.parse("2026-08-18T16:30:00", timeZone: eastern))
        let asUTC = try #require(ISODate.parse("2026-08-18T16:30:00Z"))
        // EDT is UTC-4, so reading the floating value as UTC would land it
        // four hours early.
        #expect(floating.timeIntervalSince(asUTC) == 4 * 3600)
    }

    // MARK: - designator-bearing input

    @Test("an explicit offset wins over the supplied zone")
    func explicitOffsetUnchanged() throws {
        // Parsed in UTC to prove the -04:00 designator, not the zone
        // argument, decides the instant.
        let parsed = try #require(ISODate.parse("2026-08-18T16:30:00-04:00", timeZone: utc))
        #expect(parsed.timeIntervalSince1970 == 1_787_085_000)
        let sameInstant = try #require(ISODate.parse("2026-08-18T20:30:00Z", timeZone: eastern))
        #expect(parsed == sameInstant)
    }

    @Test("accepts the compact and hour-only offset forms")
    func offsetVariants() throws {
        let canonical = try #require(ISODate.parse("2026-08-18T16:30:00-04:00"))
        #expect(try #require(ISODate.parse("2026-08-18T16:30:00-0400")) == canonical)
        #expect(try #require(ISODate.parse("2026-08-18T16:30:00-04")) == canonical)
    }

    @Test("parses Z / UTC suffix")
    func parseZulu() throws {
        let parsed = try #require(ISODate.parse("2026-08-18T20:30:00Z", timeZone: eastern))
        #expect(wall(parsed, in: utc).hour == 20)
        #expect(parsed.timeIntervalSince1970 == 1_787_085_000)
    }

    @Test("parses a bare date as midnight in the supplied zone")
    func parseBareDate() throws {
        let parsed = try #require(ISODate.parse("2026-08-18", timeZone: eastern))
        let w = wall(parsed, in: eastern)
        #expect(w.year == 2026 && w.month == 8 && w.day == 18)
        #expect(w.hour == 0 && w.minute == 0 && w.second == 0)
    }

    @Test("parses minute precision and fractional seconds")
    func parsePrecisionVariants() throws {
        let minutes = try #require(ISODate.parse("2026-08-18T16:30", timeZone: eastern))
        let seconds = try #require(ISODate.parse("2026-08-18T16:30:00", timeZone: eastern))
        #expect(minutes == seconds)

        let frac = try #require(ISODate.parse("2026-04-21T10:00:00.500Z"))
        let whole = try #require(ISODate.parse("2026-04-21T10:00:00Z"))
        #expect(abs(frac.timeIntervalSince(whole) - 0.5) < 0.01)
    }

    // MARK: - DST

    /// US Eastern leaves DST at 02:00 EDT on 2026-11-01, so an offset-less
    /// timestamp has to resolve against the offset in force at that wall
    /// clock rather than a fixed one.
    @Test("offset-less times resolve against the right DST offset")
    func dstBoundaryEastern() throws {
        let before = try #require(ISODate.parse("2026-11-01T00:30:00", timeZone: eastern))
        #expect(wall(before, in: utc).hour == 4) // EDT, UTC-4
        #expect(wall(before, in: utc).minute == 30)

        let after = try #require(ISODate.parse("2026-11-01T09:00:00", timeZone: eastern))
        #expect(wall(after, in: utc).hour == 14) // EST, UTC-5

        // 9h elapsed, not 8h30m — the 01:00 hour is lived through twice.
        #expect(after.timeIntervalSince(before) == 8.5 * 3600 + 3600)
    }

    @Test("an ambiguous fall-back wall clock resolves to its first occurrence")
    func dstAmbiguousHour() throws {
        let ambiguous = try #require(ISODate.parse("2026-11-01T01:30:00", timeZone: eastern))
        let w = wall(ambiguous, in: eastern)
        #expect(w.hour == 1 && w.minute == 30)
        #expect(eastern.secondsFromGMT(for: ambiguous) == -4 * 3600)
    }

    // MARK: - rejection

    @Test("rejects a datetime it can only partially consume")
    func rejectsPartialParse() {
        // The old implementation's failure mode: these must not quietly
        // degrade into their date half.
        #expect(ISODate.parse("2026-08-18T16:30:00 and then some") == nil)
        #expect(ISODate.parse("2026-08-18Tmorning") == nil)
        #expect(ISODate.parse("2026-08-18T16:30:00-04:00xyz") == nil)
        #expect(ISODate.parse("2026-08-18T25:00:00") == nil)
    }

    @Test("parse returns nil for garbage")
    func parseGarbage() {
        #expect(ISODate.parse("not-a-date") == nil)
        #expect(ISODate.parse("") == nil)
        #expect(ISODate.parse("18:00") == nil)
        #expect(ISODate.parse("2026-13-01") == nil)
        #expect(ISODate.parse("2026-02-30") == nil)
        #expect(ISODate.parse("08/18/2026") == nil)
    }

    @Test("accepts a real leap day and rejects a fake one")
    func leapYear() {
        #expect(ISODate.parse("2028-02-29") != nil)
        #expect(ISODate.parse("2026-02-29") == nil)
        #expect(ISODate.parse("2100-02-29") == nil)
        #expect(ISODate.parse("2000-02-29") != nil)
    }
}

@Suite("ISODate call-site compatibility")
struct ISODateCompatibilityTests {
    @Test("parse is still usable as a bare function value")
    func usableAsFunctionValue() throws {
        // Guards the reason `parse(_:)` is a separate overload rather than a
        // defaulted parameter — this call site must keep compiling.
        let parsed = ["2026-08-18T16:30:00", "nonsense"].compactMap(ISODate.parse)
        #expect(parsed.count == 1)
    }

    @Test("both overloads agree when the system zone is the one supplied")
    func overloadsAgree() throws {
        let viaDefault = try #require(ISODate.parse("2026-08-18T16:30:00"))
        let viaExplicit = try #require(
            ISODate.parse("2026-08-18T16:30:00", timeZone: .current))
        #expect(viaDefault == viaExplicit)
    }
}
