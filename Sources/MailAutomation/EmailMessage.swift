import Foundation

/// Plain value type for an email. Mirrors the Node port's shape so the same
/// LLM prompts render consistently across the two implementations.
public struct EmailMessage: Equatable, Sendable {
    public let subject: String
    public let sender: String
    public let dateSent: String  // AppleScript date string — not always ISO
    public let content: String
    public let isRead: Bool
    public let mailbox: String   // "account — mailbox" format

    public init(
        subject: String, sender: String, dateSent: String,
        content: String, isRead: Bool, mailbox: String
    ) {
        self.subject = subject
        self.sender = sender
        self.dateSent = dateSent
        self.content = content
        self.isRead = isRead
        self.mailbox = mailbox
    }
}
