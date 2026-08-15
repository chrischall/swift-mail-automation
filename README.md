# MailAutomation

[![CI](https://github.com/chrischall/swift-mail-automation/actions/workflows/ci.yml/badge.svg)](https://github.com/chrischall/swift-mail-automation/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fchrischall%2Fswift-mail-automation%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/chrischall/swift-mail-automation)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fchrischall%2Fswift-mail-automation%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/chrischall/swift-mail-automation)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Swift library for reading and sending Apple Mail on macOS. Search reads
Mail's own **Envelope Index** (SQLite) directly, so it stays fast and
correctly ordered on large accounts; AppleScript (via `NSAppleScript`)
handles sending and discovery, with Spotlight (`mdfind`) covering body
search.

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

// Search: reads Mail's Envelope Index directly — milliseconds even on a
// 275k-message mailbox, and always newest-first. Build the service with
// `withIndexIfAvailable` to enable it (needs Full Disk Access); it falls
// back to Spotlight, then AppleScript, when the index can't be opened.
let (mail, indexError) = MailService.withIndexIfAvailable(
    runner: NSAppleScriptRunner()
)
if let indexError {
    // Worth logging — the fallbacks are orders of magnitude slower.
    print("mail: fast index unavailable — \(indexError)")
}

let invoices = try await mail.search(
    query: "invoice",
    limit: 5,
    sinceDaysAgo: 90
)

// Multiple terms, boolean composition, and field scoping — one call
// instead of one call per term.
let bills = try await mail.search(
    query: "from:billing@acme.com subject:invoice OR subject:receipt",
    limit: 25,
    account: "Google",
    sinceDaysAgo: 45
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
| `getUnread(limit:account:offset:) -> [EmailMessage]` | Unread messages, optionally scoped; `offset` pages beyond the 100 safety cap |
| `search(query:limit:account:mailbox:sinceDaysAgo:offset:forceBackend:) -> [EmailMessage]` | Boolean/field-scoped search, index-first, **newest-first**; `offset` for paging |
| `getMessage(id:account:) -> MailMessageDetail` | One message's **complete, untruncated** body by its `messageId` |
| `send(to:subject:body:cc:bcc:)` | Compose + send a new message |

`getUnread`/`search` return a truncated `EmailMessage.content` preview plus
a stable `messageId`; pass that id to `getMessage` for the full body.

### Query syntax

`search(query:)` takes more than a single keyword:

| Query | Meaning |
|---|---|
| `invoice` | subject or sender contains "invoice" |
| `invoice overdue` | both terms (implicit AND) |
| `invoice OR receipt` | either term (`OR` must be uppercase) |
| `invoice overdue OR receipt` | AND binds tighter than OR |
| `"past due"` | quoted phrase, one term |
| `from:alice@x.com` | sender |
| `to:bob@x.com` | any recipient (index backend only) |
| `subject:invoice` | subject only |
| `from:billing@x.co subject:invoice` | scopes combine with AND |

An empty query is **rejected**, not treated as "match everything".

### `SearchBackend`

`search(forceBackend:)` accepts:
- `.index` — Mail's Envelope Index. Fast, date-sorted, knows accounts /
  mailboxes / read state / recipients. Needs Full Disk Access.
- `.spotlight` — `mdfind`. The only backend that searches message
  **bodies**; can't scope by account or mailbox.
- `.applescript` — drives Mail.app. Last resort; see the warning below.
- `nil` (default) — index, then Spotlight (when unscoped), then AppleScript.

### Why the index is the default

Mail's AppleScript `whose` cost scales with the number of *matches*, not
with the `limit` you pass, and a `count of` costs the same as fetching —
so there is no cheap way to ask Mail how big an answer would be before
committing to it. Measured against one Gmail mailbox of 275,422 messages,
searching subjects over a 45-day window:

| matches | Mail.app `whose` | Envelope Index |
|---|---|---|
| 0 | 0.5 s | — |
| 18 | 23.7 s | — |
| 153 | **154 s** | **0.05 s** |

Worse, with AppleScript's implicit 60 s event timeout the 153-match query
returns **nothing at all** — the timeout used to be caught by a
per-mailbox `try`, so the search reported an empty result set rather than
a failure. That is now a
`MailServiceError.timedOut(operation:seconds:)`; a timeout is never
rendered as "no results".

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
- Boolean, field-scoped search (`AND`/`OR`, `from:`/`to:`/`subject:`),
  date-bounded and newest-first
- Send with optional cc/bcc, multi-line bodies, quoted content

**Limits:**
- Spotlight search requires `~/Library/Mail` to be indexed by the
  system. Check System Settings → Siri & Spotlight → Search Privacy
  if results are empty.
- Without Full Disk Access there is no index, and search falls back to
  Spotlight or AppleScript. The AppleScript path is slow on Gmail-heavy
  setups no matter what `limit` you pass (see above) — it is bounded and
  reports timeouts honestly, but it cannot be made fast.
- `to:` search needs the index; Mail's `whose` cannot express it, so the
  AppleScript backend refuses the query rather than silently dropping the
  constraint.
- The index carries no message *bodies*, so `EmailMessage.content` is
  empty on index results — call `getMessage(id:)` for the body, or force
  the Spotlight backend to search body text.
- No IMAP/SMTP — this is a local Mail.app wrapper, not a mail
  client library. For that, use MailCore2.
- Spotlight results always report `isRead == true` because Spotlight
  doesn't index read state.

## Permissions

The calling process needs:

- **Automation** for Mail (System Settings → Privacy & Security →
  Automation → Your binary → Mail)
- **Full Disk Access** on the calling binary, for both the Envelope
  Index and Spotlight. FDA is not an `Info.plist` key — it's a user
  toggle in System Settings → Privacy & Security → Full Disk Access.
  Without it, `MailService.withIndexIfAvailable` returns the reason in
  its `indexError`; log it, because the fallbacks are far slower.

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
