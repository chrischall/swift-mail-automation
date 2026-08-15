import Foundation
@testable import MailAutomation
import Testing

@Suite("MailQuery")
struct MailQueryTests {
    // ─── Parsing: single terms ─────────────────────────────────────────────

    @Test("a bare word parses to one AND-group with one any-field term")
    func bareWord() throws {
        let q = try MailQuery.parse("invoice")
        #expect(q.groups.count == 1)
        #expect(q.groups[0] == [MailQuery.Term(field: .any, value: "invoice")])
    }

    @Test("whitespace-separated words are ANDed")
    func impliedAnd() throws {
        let q = try MailQuery.parse("invoice overdue")
        #expect(q.groups.count == 1)
        #expect(q.groups[0].map(\.value) == ["invoice", "overdue"])
        #expect(q.groups[0].allSatisfy { $0.field == .any })
    }

    @Test("an explicit AND keyword reads the same as whitespace")
    func explicitAnd() throws {
        let a = try MailQuery.parse("invoice AND overdue")
        let b = try MailQuery.parse("invoice overdue")
        #expect(a == b)
    }

    @Test("OR splits into separate AND-groups")
    func orSplits() throws {
        let q = try MailQuery.parse("invoice OR receipt")
        #expect(q.groups.count == 2)
        #expect(q.groups[0].map(\.value) == ["invoice"])
        #expect(q.groups[1].map(\.value) == ["receipt"])
    }

    @Test("AND binds tighter than OR")
    func precedence() throws {
        let q = try MailQuery.parse("invoice overdue OR receipt")
        #expect(q.groups.count == 2)
        #expect(q.groups[0].map(\.value) == ["invoice", "overdue"])
        #expect(q.groups[1].map(\.value) == ["receipt"])
    }

    @Test("lowercase 'or' is a literal search term, not an operator")
    func lowercaseOrIsLiteral() throws {
        let q = try MailQuery.parse("invoice or receipt")
        #expect(q.groups.count == 1)
        #expect(q.groups[0].map(\.value) == ["invoice", "or", "receipt"])
    }

    // ─── Parsing: field scoping ────────────────────────────────────────────

    @Test("from: scopes a term to the sender")
    func fromScope() throws {
        let q = try MailQuery.parse("from:alice@example.com")
        #expect(q.groups[0] == [MailQuery.Term(field: .from, value: "alice@example.com")])
    }

    @Test("to: scopes a term to the recipients")
    func toScope() throws {
        let q = try MailQuery.parse("to:bob@example.com")
        #expect(q.groups[0] == [MailQuery.Term(field: .to, value: "bob@example.com")])
    }

    @Test("subject: scopes a term to the subject")
    func subjectScope() throws {
        let q = try MailQuery.parse("subject:invoice")
        #expect(q.groups[0] == [MailQuery.Term(field: .subject, value: "invoice")])
    }

    @Test("field prefixes are case-insensitive")
    func fieldCaseInsensitive() throws {
        let q = try MailQuery.parse("From:alice SUBJECT:bill")
        #expect(q.groups[0] == [
            MailQuery.Term(field: .from, value: "alice"),
            MailQuery.Term(field: .subject, value: "bill"),
        ])
    }

    @Test("scoped and unscoped terms mix freely")
    func mixedScopes() throws {
        let q = try MailQuery.parse("from:alice invoice OR subject:receipt")
        #expect(q.groups.count == 2)
        #expect(q.groups[0] == [
            MailQuery.Term(field: .from, value: "alice"),
            MailQuery.Term(field: .any, value: "invoice"),
        ])
        #expect(q.groups[1] == [MailQuery.Term(field: .subject, value: "receipt")])
    }

    @Test("an unknown prefix stays part of the literal term")
    func unknownPrefixIsLiteral() throws {
        let q = try MailQuery.parse("cc:alice")
        #expect(q.groups[0] == [MailQuery.Term(field: .any, value: "cc:alice")])
    }

    // ─── Parsing: quoting ──────────────────────────────────────────────────

    @Test("a quoted phrase is one term including its spaces")
    func quotedPhrase() throws {
        let q = try MailQuery.parse("\"past due invoice\"")
        #expect(q.groups[0] == [MailQuery.Term(field: .any, value: "past due invoice")])
    }

    @Test("a field prefix applies to a following quoted phrase")
    func quotedAfterField() throws {
        let q = try MailQuery.parse("subject:\"past due\" from:alice")
        #expect(q.groups[0] == [
            MailQuery.Term(field: .subject, value: "past due"),
            MailQuery.Term(field: .from, value: "alice"),
        ])
    }

    @Test("OR inside quotes is a literal, not an operator")
    func quotedOrIsLiteral() throws {
        let q = try MailQuery.parse("\"invoice OR receipt\"")
        #expect(q.groups.count == 1)
        #expect(q.groups[0] == [MailQuery.Term(field: .any, value: "invoice OR receipt")])
    }

    @Test("an unterminated quote runs to end of input rather than throwing")
    func unterminatedQuote() throws {
        let q = try MailQuery.parse("subject:\"past due")
        #expect(q.groups[0] == [MailQuery.Term(field: .subject, value: "past due")])
    }

    // ─── Parsing: rejection ────────────────────────────────────────────────

    @Test("an empty query throws rather than matching everything")
    func emptyThrows() {
        for input in ["", "   ", "\t\n"] {
            #expect(throws: MailQueryError.self) { _ = try MailQuery.parse(input) }
        }
    }

    @Test("a query of only operators throws")
    func operatorsOnlyThrows() {
        #expect(throws: MailQueryError.self) { _ = try MailQuery.parse("OR AND") }
    }

    @Test("a field prefix with no value throws")
    func danglingFieldThrows() {
        #expect(throws: MailQueryError.self) { _ = try MailQuery.parse("from:") }
    }

    @Test("a dangling OR does not produce an empty group that matches everything")
    func danglingOr() throws {
        let q = try MailQuery.parse("invoice OR")
        #expect(q.groups.count == 1)
        #expect(q.groups[0].map(\.value) == ["invoice"])
    }

    // ─── SQL compilation ───────────────────────────────────────────────────

    @Test("a single term compiles to a parameterised LIKE, never inline text")
    func sqlParameterised() throws {
        let (sql, args) = try MailQuery.parse("invoice").sqlPredicate()
        #expect(!sql.contains("invoice"), "term must not be inlined into SQL")
        // One bind per column an `any` term is matched against.
        #expect(args == ["%invoice%", "%invoice%"])
    }

    @Test("AND terms compile to AND, OR groups to OR")
    func sqlBoolean() throws {
        let (sql, args) = try MailQuery.parse("a b OR c").sqlPredicate()
        #expect(sql.contains(" AND "))
        #expect(sql.contains(" OR "))
        #expect(args == ["%a%", "%a%", "%b%", "%b%", "%c%", "%c%"])
    }

    @Test("field scoping selects the matching SQL column")
    func sqlColumns() throws {
        let (subjectSQL, _) = try MailQuery.parse("subject:x").sqlPredicate()
        #expect(subjectSQL.contains("subject"))

        let (fromSQL, _) = try MailQuery.parse("from:x").sqlPredicate()
        #expect(fromSQL.contains("sender"))

        let (toSQL, _) = try MailQuery.parse("to:x").sqlPredicate()
        #expect(toSQL.contains("recipient"))
    }

    @Test("an any-field term searches subject and sender together")
    func sqlAnyField() throws {
        let (sql, args) = try MailQuery.parse("x").sqlPredicate()
        #expect(sql.contains("subject"))
        #expect(sql.contains("sender"))
        // One bind per column the term is matched against.
        #expect(args == ["%x%", "%x%"])
    }

    @Test("LIKE wildcards in user input are escaped so they match literally")
    func sqlEscapesWildcards() throws {
        let (sql, args) = try MailQuery.parse("100%_off").sqlPredicate()
        #expect(args.allSatisfy { $0.contains("100\\%\\_off") })
        #expect(sql.contains("ESCAPE"), "LIKE needs an ESCAPE clause for the escaping to take effect")
    }

    @Test("a single quote in the term stays a bind argument and cannot break the SQL")
    func sqlQuoteSafe() throws {
        let (sql, args) = try MailQuery.parse("o'brien").sqlPredicate()
        #expect(!sql.contains("o'brien"))
        #expect(args == ["%o'brien%", "%o'brien%"])
    }

    // ─── AppleScript compilation ───────────────────────────────────────────

    @Test("AppleScript predicate ANDs terms and ORs groups with explicit parens")
    func appleScriptBoolean() throws {
        let p = try MailQuery.parse("a b OR c").appleScriptPredicate()
        #expect(p.contains("and"))
        #expect(p.contains("or"))
        #expect(p.hasPrefix("("))
    }

    @Test("AppleScript predicate escapes embedded quotes so it cannot break out of the literal")
    func appleScriptEscapes() throws {
        // Term text containing a bare double quote. Unescaped, that quote
        // terminates the AppleScript string literal and everything after it
        // is parsed as code.
        let q = try MailQuery.parse(#"hi"there"#)
        #expect(q.groups[0][0].value == #"hi"there"#)

        let p = try q.appleScriptPredicate()
        #expect(p.contains(#"hi\"there"#), "the quote must be backslash-escaped: \(p)")
        #expect(!p.contains(#"contains "hi"there""#), "unescaped, this breaks out of the literal")
    }

    @Test("AppleScript predicate escapes a trailing backslash")
    func appleScriptEscapesTrailingBackslash() throws {
        // `foo\` would otherwise escape the literal's own closing quote and
        // swallow it.
        let q = try MailQuery.parse(#"foo\"#)
        #expect(q.groups[0][0].value == #"foo\"#)

        let p = try q.appleScriptPredicate()
        // Doubled, and the literal still closes right after it — an
        // undoubled `foo\` would eat the closing quote instead.
        #expect(p.contains(#"contains "foo\\")"#), "expected an escaped, closed literal: \(p)")
    }

    @Test("to: is rejected on the AppleScript backend, which cannot express it")
    func appleScriptRejectsTo() throws {
        let q = try MailQuery.parse("to:alice")
        #expect(throws: MailQueryError.self) { _ = try q.appleScriptPredicate() }
    }
}
