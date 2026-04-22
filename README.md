# MailAutomation

[![CI](https://github.com/chrischall/swift-mail-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/chrischall/swift-mail-automation/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fchrischall%2Fswift-mail-automation%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/chrischall/swift-mail-automation)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fchrischall%2Fswift-mail-automation%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/chrischall/swift-mail-automation)

Swift library for driving Apple Mail.app on macOS. Wraps AppleScript (via
`NSAppleScript`) for read/send/discovery operations, and uses Spotlight
(via `mdfind`) as a fast fallback path for content search.

Platform: **macOS 14+**. Pure Swift 6 with strict concurrency. Single
dependency: `swift-log`.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/chrischall/swift-mail-automation.git", from: "1.0.0"),
]
```

## Quickstart

```swift
import MailAutomation

let mail = MailService(runner: NSAppleScriptRunner())

// Discover what's configured in Mail.app
let accounts = try await mail.listAccounts()
// ["iCloud", "Google", "Work"]

let iCloudBoxes = try await mail.listMailboxes(account: "iCloud")
// ["INBOX", "Sent", "Drafts", ...]

// Unread mail (across all accounts, or scoped)
let unread = try await mail.getUnread(limit: 10)
let workUnread = try await mail.getUnread(limit: 10, account: "Work")

// Search: tries Spotlight first (sub-second when indexed), falls back
// to AppleScript whose() with a date bound. Scoping by account/mailbox
// forces the AppleScript path since Spotlight doesn't know about
// Mail's account grouping.
let invoices = try await mail.search(
    query: "invoice",
    limit: 5,
    sinceDaysAgo: 90
)

// Send — with optional cc/bcc, file-backed body so multi-line +
// quotes don't need escaping.
try await mail.send(
    to: "alice@example.com",
    subject: "Hi",
    body: "Multi-line\nbody\n\"with quotes\"",
    cc: "bob@example.com"
)
```

## API reference

### `MailService`

The main entry point. Construct once, reuse across calls. All methods
are async and throw `AppleScriptError` or `MailServiceError`.

| Method | Purpose |
|---|---|
| `listAccounts() -> [String]` | Discover Mail account names (`"iCloud"`, `"Google"`, …) |
| `listMailboxes(account:) -> [String]` | Mailboxes inside an account |
| `getUnread(limit:account:) -> [EmailMessage]` | Unread messages, optionally scoped |
| `search(query:limit:account:mailbox:sinceDaysAgo:forceBackend:) -> [EmailMessage]` | Subject+body search, Spotlight-first with AppleScript fallback |
| `send(to:subject:body:cc:bcc:)` | Compose + send a new message |

### `SearchBackend`

`search(forceBackend:)` accepts:
- `.spotlight` — forces Spotlight regardless of scoping
- `.applescript` — forces the AppleScript path (slower but knows read-state and mailbox)
- `nil` (default) — Spotlight when unscoped and indexed; AppleScript otherwise

### `EmailMessage`

Value type returned from search / unread:

```swift
subject: String
sender: String              // "Name <addr@example.com>"
dateSent: String            // AppleScript date string
content: String             // truncated body preview
isRead: Bool                // false for unread; always true for Spotlight hits
mailbox: String             // "account — mailbox"
```

### `AppleScriptRunner` / `NSAppleScriptRunner`

Protocol + production impl. Inject a fake in unit tests (see below).

## Capabilities and limits

**Supported:**
- List accounts + mailboxes
- Read unread mail (across accounts or scoped)
- Subject + body search, date-bounded, with Spotlight fast path
- Send with optional cc/bcc, multi-line bodies, quoted content

**Limits:**
- Spotlight search requires `~/Library/Mail` to be indexed by the
  system. Check System Settings → Siri & Spotlight → Search Privacy
  if results are empty.
- AppleScript-backed operations are slow on Gmail-heavy setups —
  Mail.app iterates each label as a separate mailbox. Scope with
  `account` + `mailbox` when possible.
- No IMAP/SMTP — this is a local Mail.app wrapper, not a mail
  client library. For that, use MailCore2.
- Spotlight results always report `isRead == true` because Spotlight
  doesn't index read state.

## Permissions

The calling process needs:

- **Automation** for Mail (System Settings → Privacy & Security →
  Automation → Your binary → Mail)
- For Spotlight search: **Full Disk Access** on the calling binary
  so `mdfind` can read the Mail index.

On macOS 14+ your binary's `Info.plist` should declare
`NSAppleEventsUsageDescription` and, if you intend to use Spotlight,
ensure it's granted FDA.

## Testing

`AppleScriptRunner` is a protocol, so you can inject a fake in unit
tests:

```swift
import MailAutomation

final class MyFakeRunner: AppleScriptRunner {
    var response = ""
    func run(source: String) async throws -> String { response }
}

let mail = MailService(runner: MyFakeRunner())
```

## License

MIT. See [LICENSE](LICENSE).
