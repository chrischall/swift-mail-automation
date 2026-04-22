import Foundation

public extension String {
    /// Returns `self` when the string is non-empty, else `nil`.
    ///
    /// Handy for nil-coalescing chains that want to treat empty strings
    /// as "absent", e.g.:
    ///
    /// ```swift
    /// let effective = explicit?.nonEmpty ?? envDefault ?? "fallback"
    /// ```
    var nonEmpty: String? { isEmpty ? nil : self }
}
