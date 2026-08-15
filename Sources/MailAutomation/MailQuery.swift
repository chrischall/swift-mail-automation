import Foundation

/// Errors raised while parsing or compiling a ``MailQuery``.
public enum MailQueryError: Error, Equatable, Sendable {
    /// The query had no searchable terms — empty, whitespace-only, or
    /// nothing but boolean operators. Rejected rather than treated as
    /// "match everything", which is the shape of query that takes Mail
    /// down.
    case empty
    /// A field prefix (`from:`, `to:`, `subject:`) was given with no value
    /// after it.
    case danglingField(String)
    /// The chosen backend can't express this term. Carries the field name
    /// and the reason.
    case unsupportedField(field: String, backend: String)
}

/// A parsed mail search query.
///
/// Supports multiple terms with boolean composition and per-field scoping,
/// so a caller needing N terms makes one call instead of N:
///
/// ```
/// invoice overdue                 → subject/sender contains both
/// invoice OR receipt              → either
/// from:alice subject:invoice      → sender AND subject, scoped
/// "past due" OR from:billing@x.co → quoted phrase, or that sender
/// ```
///
/// Grammar, informally:
/// - Terms are whitespace-separated. A `"quoted phrase"` is one term.
/// - Adjacent terms are ANDed. `AND` may be written explicitly.
/// - `OR` (uppercase, unquoted) separates AND-groups. AND binds tighter.
/// - A term may carry a `from:`, `to:`, or `subject:` prefix. Unprefixed
///   terms match subject or sender.
/// - `or` / `and` in lowercase are ordinary search terms, so searching for
///   the literal words still works.
///
/// The parsed form is disjunctive normal form: ``groups`` is an OR of
/// AND-groups. Compile it with ``sqlPredicate()`` for the index backend or
/// ``appleScriptPredicate()`` for the Mail.app backend.
public struct MailQuery: Equatable, Sendable {
    /// Which part of a message a term is matched against.
    public enum Field: String, Equatable, Sendable {
        /// Subject or sender. The default for an unprefixed term.
        case any
        /// The sender address / display name.
        case from
        /// Any recipient address (to, cc, bcc).
        case to
        /// The subject line only.
        case subject
    }

    /// One search term: a substring plus the field it applies to.
    public struct Term: Equatable, Sendable {
        public let field: Field
        public let value: String

        public init(field: Field, value: String) {
            self.field = field
            self.value = value
        }
    }

    /// OR of AND-groups. `[[a, b], [c]]` means `(a AND b) OR c`.
    public let groups: [[Term]]

    // MARK: - Parsing

    /// Parse a user-supplied query string.
    ///
    /// - Parameter raw: The query. See the type documentation for the
    ///   grammar.
    /// - Returns: The parsed query in disjunctive normal form.
    /// - Throws: ``MailQueryError/empty`` when nothing searchable remains
    ///   (this is deliberate — an empty query must never be silently
    ///   promoted to "match everything"), or
    ///   ``MailQueryError/danglingField(_:)`` for a prefix with no value.
    public static func parse(_ raw: String) throws -> MailQuery {
        let tokens = try tokenize(raw)
        var groups: [[Term]] = []
        var current: [Term] = []

        for token in tokens {
            switch token {
            case .or:
                // Drop an empty group rather than emitting one — an empty
                // AND-group matches everything, which is the failure mode
                // this whole type exists to prevent.
                if !current.isEmpty {
                    groups.append(current)
                }
                current = []
            case .and:
                continue
            case let .term(field, value):
                current.append(Term(field: field, value: value))
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }

        guard !groups.isEmpty else { throw MailQueryError.empty }
        return MailQuery(groups: groups)
    }

    private enum Token {
        case term(Field, String)
        case and
        case or
    }

    /// Split the raw query into tokens, honouring quoted phrases and
    /// field prefixes.
    private static func tokenize(_ raw: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(raw)
        var i = 0

        while i < chars.count {
            // Skip whitespace between tokens.
            while i < chars.count, chars[i].isWhitespace {
                i += 1
            }
            guard i < chars.count else { break }

            // A field prefix binds to whatever term follows, quoted or not,
            // so it is consumed before the value is read.
            var field = Field.any
            if let (parsed, next) = readFieldPrefix(chars, from: i) {
                field = parsed
                i = next
            }

            let value: String
            if i < chars.count, chars[i] == "\"" {
                // Quoted phrase: everything up to the closing quote is one
                // term, operators included. An unterminated quote runs to
                // end of input — friendlier than rejecting a half-typed
                // query outright.
                i += 1
                var buf = ""
                while i < chars.count, chars[i] != "\"" {
                    buf.append(chars[i])
                    i += 1
                }
                if i < chars.count {
                    i += 1
                } // closing quote
                value = buf
            } else {
                var buf = ""
                while i < chars.count, !chars[i].isWhitespace {
                    buf.append(chars[i])
                    i += 1
                }
                value = buf
            }

            if value.isEmpty {
                // `from:` with nothing after it. Dropping it would quietly
                // widen the search to every message, so say so instead.
                if field != .any {
                    throw MailQueryError.danglingField(field.rawValue)
                }
                continue
            }

            // Operators are only operators when bare and uppercase — a
            // quoted or field-scoped "OR" is a literal search term.
            if field == .any {
                if value == "OR" {
                    tokens.append(.or); continue
                }
                if value == "AND" {
                    tokens.append(.and); continue
                }
            }
            tokens.append(.term(field, value))
        }

        return tokens
    }

    /// Reads a `from:` / `to:` / `subject:` prefix at `start`.
    ///
    /// - Returns: The field and the index just past the colon, or `nil`
    ///   when no known prefix is present (so `cc:alice` stays a literal).
    private static func readFieldPrefix(
        _ chars: [Character], from start: Int
    ) -> (Field, Int)? {
        for (name, field) in [("from:", Field.from), ("to:", .to), ("subject:", .subject)] {
            let n = name.count
            guard start + n <= chars.count else { continue }
            let candidate = String(chars[start ..< (start + n)]).lowercased()
            guard candidate == name else { continue }
            return (field, start + n)
        }
        return nil
    }

    // MARK: - SQL compilation

    /// Columns the index backend exposes to a query, by field.
    ///
    /// `any` deliberately omits the body: the index stores no body text,
    /// and asking Mail.app for one is what makes the AppleScript backend
    /// unusable. Body search belongs to the Spotlight backend.
    private static func sqlColumns(for field: Field) -> [String] {
        switch field {
        case .any: ["subject_text", "sender_text"]
        case .from: ["sender_text"]
        case .to: ["recipient_text"]
        case .subject: ["subject_text"]
        }
    }

    /// The character used to escape LIKE metacharacters in bind arguments.
    static let likeEscape: Character = "\\"

    /// Compile to a parameterised SQL predicate for the index backend.
    ///
    /// Term text is **never** interpolated into the SQL — it comes back as
    /// bind arguments, so a query containing quotes, `%`, or `_` is matched
    /// literally and can't alter the statement.
    ///
    /// - Returns: A predicate safe to drop into a `WHERE` clause, and the
    ///   bind arguments in positional order.
    func sqlPredicate() throws -> (sql: String, args: [String]) {
        var args: [String] = []
        var orClauses: [String] = []

        for group in groups {
            var andClauses: [String] = []
            for term in group {
                let needle = "%\(Self.escapeForLike(term.value))%"
                let columns = Self.sqlColumns(for: term.field)
                let perColumn = columns.map { col in
                    args.append(needle)
                    return "\(col) LIKE ? ESCAPE '\(Self.likeEscape)'"
                }
                andClauses.append("(" + perColumn.joined(separator: " OR ") + ")")
            }
            orClauses.append("(" + andClauses.joined(separator: " AND ") + ")")
        }

        return ("(" + orClauses.joined(separator: " OR ") + ")", args)
    }

    /// Escapes LIKE metacharacters so user input matches literally.
    ///
    /// Without this, a query for `100%` matches every subject. The escape
    /// character itself is escaped first, or escaping it later would
    /// double-escape.
    static func escapeForLike(_ value: String) -> String {
        let e = String(likeEscape)
        return value
            .replacingOccurrences(of: e, with: e + e)
            .replacingOccurrences(of: "%", with: e + "%")
            .replacingOccurrences(of: "_", with: e + "_")
    }

    // MARK: - AppleScript compilation

    /// Compile to an AppleScript `whose` predicate for the Mail.app
    /// backend.
    ///
    /// - Throws: ``MailQueryError/unsupportedField(field:backend:)`` for
    ///   `to:` — Mail's `whose` can't compare against `to recipients`
    ///   (it fails with *Can't make "…" into type to recipient*), so the
    ///   caller is told rather than silently handed a query that drops the
    ///   constraint.
    func appleScriptPredicate() throws -> String {
        var orClauses: [String] = []

        for group in groups {
            var andClauses: [String] = []
            for term in group {
                let esc = MailService.escapeForAppleScript(term.value)
                switch term.field {
                case .subject:
                    andClauses.append("(subject contains \"\(esc)\")")
                case .from:
                    andClauses.append("(sender contains \"\(esc)\")")
                case .any:
                    andClauses.append(
                        "((subject contains \"\(esc)\") or (sender contains \"\(esc)\"))"
                    )
                case .to:
                    throw MailQueryError.unsupportedField(
                        field: "to", backend: "applescript"
                    )
                }
            }
            orClauses.append("(" + andClauses.joined(separator: " and ") + ")")
        }

        return "(" + orClauses.joined(separator: " or ") + ")"
    }
}
