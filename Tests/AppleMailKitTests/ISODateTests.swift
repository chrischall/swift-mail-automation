import Foundation
import Testing
@testable import AppleMailKit

@Suite("ISODate")
struct ISODateTests {
    @Test("round-trips a UTC date through string→parse")
    func roundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_745_230_200)  // 2026-04-21T10:50:00Z
        let s = ISODate.string(from: original)
        let parsed = try #require(ISODate.parse(s))
        #expect(abs(parsed.timeIntervalSince(original)) < 1)
    }

    @Test("parses a bare date as midnight local time")
    func parseBareDate() throws {
        let parsed = try #require(ISODate.parse("2026-04-21"))
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
        #expect(comps.year == 2026)
        #expect(comps.month == 4)
        #expect(comps.day == 21)
    }

    @Test("parses datetime with fractional seconds")
    func parseFractional() throws {
        let parsed = try #require(ISODate.parse("2026-04-21T10:00:00.500Z"))
        let whole = try #require(ISODate.parse("2026-04-21T10:00:00Z"))
        #expect(abs(parsed.timeIntervalSince(whole) - 0.5) < 0.01)
    }

    @Test("parse returns nil for garbage")
    func parseGarbage() {
        #expect(ISODate.parse("not-a-date") == nil)
        #expect(ISODate.parse("") == nil)
    }
}
