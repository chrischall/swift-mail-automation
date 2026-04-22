import Foundation
@testable import MailAutomation
import Testing

@Suite("String.nonEmpty")
struct StringHelpersTests {
    @Test("returns self for non-empty strings")
    func nonEmptyReturnsSelf() {
        #expect("hello".nonEmpty == "hello")
        #expect(" ".nonEmpty == " ") // whitespace is still non-empty
    }

    @Test("returns nil for empty strings")
    func nonEmptyReturnsNilForEmpty() {
        #expect("".nonEmpty == nil)
    }

    @Test("composes naturally in optional-chain precedence")
    func nonEmptyInChain() {
        let explicit: String? = ""
        let fallback: String? = "default"
        let result = explicit?.nonEmpty ?? fallback
        #expect(result == "default")
    }
}
