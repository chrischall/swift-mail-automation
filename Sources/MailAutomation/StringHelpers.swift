import Foundation

extension String {
    /// Returns self if non-empty, else nil. Handy for precedence chains
    /// like `explicit ?? envDefault ?? throw`.
    public var nonEmpty: String? { isEmpty ? nil : self }
}
