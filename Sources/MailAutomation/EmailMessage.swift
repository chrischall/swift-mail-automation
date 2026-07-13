import Foundation

/// A single email message returned from `MailService`.
///
/// Decoupled from Mail.app's underlying representation — pure value type
/// so consumers and tests never need to touch AppleScript objects.
public struct EmailMessage: Equatable, Sendable {
    /// Subject line.
    public let subject: String

    /// Sender, formatted as `"Name <addr@example.com>"` or bare address.
    public let sender: String

    /// Date the message was sent, as rendered by AppleScript (e.g.
    /// `"Saturday, April 19, 2026 at 10:53:12 AM"`) or ISO-ish from
    /// Spotlight. Consumers that need a `Date` should parse or call
    /// Mail.app directly for the message's raw date.
    public let dateSent: String

    /// First chars of the body, truncated to ~300 chars with a trailing
    /// `"..."`. Empty when content couldn't be read (protected / encrypted
    /// message, permissions, etc.).
    public let content: String

    /// Whether the message is marked read. Always `false` for messages
    /// returned by `getUnread`; always `true` for messages returned by
    /// `SpotlightMailSearch` (Spotlight doesn't index read state).
    public let isRead: Bool

    /// Formatted as `"account — mailbox"`, e.g. `"iCloud — INBOX"` or
    /// `"Google — [Gmail]/All Mail"`. Handy for the LLM / UI to display
    /// context without a second call.
    public let mailbox: String

    /// The RFC 2822 `Message-ID` header — a stable, globally-unique handle
    /// for the message. Pass it to ``MailService/getMessage(id:account:)``
    /// to fetch the complete, untruncated body. Empty when the backend
    /// didn't provide one (e.g. Spotlight results, or the legacy parse
    /// format).
    public let messageId: String

    /// Create an `EmailMessage`. Exposed so callers can construct fixtures
    /// in tests; the library itself builds these from parsed AppleScript
    /// or Spotlight output.
    ///
    /// - Parameters:
    ///   - subject: Subject line.
    ///   - sender: Formatted sender (`"Name <addr@example.com>"` or bare).
    ///   - dateSent: Date string as rendered by the backend. See `dateSent`.
    ///   - content: Body preview (may be empty).
    ///   - isRead: Read-state flag. See `isRead` for backend semantics.
    ///   - mailbox: `"account — mailbox"` context string.
    ///   - messageId: RFC Message-ID, or `""` when unavailable.
    public init(
        subject: String, sender: String, dateSent: String,
        content: String, isRead: Bool, mailbox: String,
        messageId: String = ""
    ) {
        self.subject = subject
        self.sender = sender
        self.dateSent = dateSent
        self.content = content
        self.isRead = isRead
        self.mailbox = mailbox
        self.messageId = messageId
    }
}

/// A single message's **complete** contents, returned by
/// ``MailService/getMessage(id:account:)``.
///
/// Where ``EmailMessage/content`` is a ~300-char preview, ``body`` here is
/// the message's full, untruncated plain-text body with newlines preserved.
public struct MailMessageDetail: Equatable, Sendable {
    public let messageId: String
    public let subject: String
    public let sender: String
    public let dateSent: String
    /// `"account — mailbox"` context string.
    public let mailbox: String
    public let isRead: Bool
    /// The complete, untruncated body. Newlines preserved.
    public let body: String

    public init(
        messageId: String, subject: String, sender: String, dateSent: String,
        mailbox: String, isRead: Bool, body: String
    ) {
        self.messageId = messageId
        self.subject = subject
        self.sender = sender
        self.dateSent = dateSent
        self.mailbox = mailbox
        self.isRead = isRead
        self.body = body
    }
}
