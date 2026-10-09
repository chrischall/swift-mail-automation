# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Swift Package Manager project, macOS 14+, Swift 6 with strict concurrency.

```bash
swift build               # build the library
swift build -c release    # optimised build
swift test                # all unit tests (integration tests skip by default)

# Run a single test / suite (Swift Testing, not XCTest)
swift test --filter MailServiceTests
swift test --filter MailServiceTests.parseUnread
swift test --filter "MailService integration"

# Formatting (config: .swiftformat)
swiftformat Sources Tests          # apply formatting
swiftformat Sources Tests --lint   # check only, non-zero exit on diffs

# Coverage (llvm-cov against the test binary's profdata)
swift test --enable-code-coverage
xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/swift-mail-automationPackageTests.xctest/Contents/MacOS/swift-mail-automationPackageTests \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  -ignore-filename-regex='.build|Tests'
```

Integration tests in `MailServiceIntegrationTests.swift` are gated by env vars so CI and normal `swift test` stay deterministic:

- `MAIL_AUTOMATION_INTEGRATION=1` — enables read-only tests (`listAccounts`, `listMailboxes`, `getUnread`). Requires Automation permission on Mail for the test binary.
- `MAIL_AUTOMATION_SEND_TO=<your-address>` — additionally enables the send round-trip test. Only ever set this to an address you control (it sends a `[MailAutomation-SelfTest]`-tagged message).

## Architecture

This is a **local Mail.app wrapper**, not a mail client. No IMAP/SMTP. Reads go to Mail's own Envelope Index (SQLite, needs Full Disk Access) when it can be opened, then Spotlight (`mdfind`), then AppleScript against the running Mail.app. Sends, `getMessage`, and account/mailbox discovery go through AppleScript.

**Layering (Sources/MailAutomation/):**

- `MailService` — the single public entry point. Owns the index → Spotlight → AppleScript backend choice for `search` and `getUnread`; for the AppleScript path it builds source strings, dispatches them through an injected `AppleScriptRunner`, and parses tab-delimited results via `parseEmailLines` / `parseSearchLines`.
- `MailIndexReader` — an `actor` that queries Mail's Envelope Index (`~/Library/Mail/V*/MailData/Envelope Index`) and resolves account names from `Accounts4.sqlite`. Opening it needs Full Disk Access; `MailService.withIndexIfAvailable` degrades to the other backends when it can't. `CMailSQLite` is a one-function C shim for `sqlite3_db_config`, which is variadic and so can't be called from Swift.
- `MailQuery` — parses the search string (terms, `AND`/`OR`, `from:`/`to:`/`subject:`) and renders it per backend (SQL predicate, `mdfind` predicate, AppleScript `whose`).
- `MailTimeout` — `MailTimeouts` (the in-script `with timeout` bound plus the Swift-side operation bound), `withTimeout`, and `ScriptStartGate` for sends.
- `AppleScriptRunner` (protocol) + `NSAppleScriptRunner` (production impl). The production impl constructs and runs the script entirely inside a hop to the **main thread** (`NSAppleScriptRunner.onMainThread(_:)`, backed by `MainActor.run`). That keeps the non-`Sendable` `NSAppleScript` lifecycle on one thread *and* is load-bearing for correctness: a script targeting another app waits for its Apple Event reply inside Carbon's `AEDefaultActiveProc`, which pumps only the main thread's event queue — where the reply is delivered. Run off the main thread it stalls (~32s on one measurement, no return before a 200s timeout on another) with no error and no timeout. Do not move this back to a detached `Task`. Tests inject a fake instead.
- `SpotlightMailSearch` — subprocesses `/usr/bin/mdfind` against `~/Library/Mail`. Chose `mdfind` over `NSMetadataQuery` because the latter needs a RunLoop and fights Swift 6 strict concurrency. The `Runner` typealias lets tests inject a fake process runner. The default runner terminates `mdfind` when its task is cancelled (which is what `withTimeout` does on expiry), so a timed-out query doesn't leave the child and its pipe-reader threads running.
- `EmailMessage`, `ISODate`, `StringHelpers` — value types / shared helpers. All public types are `Sendable`.

**Key invariants to preserve when editing:**

- **AppleScript output shape.** `getUnread` emits 7 tab-separated fields per line (`subject, sender, date, mailbox, account, body, messageId`) and parses through `parseEmailLines`. `search` emits 9 (`subject, sender, date, mailbox, account, isRead, body, messageId, sortKey`) and parses through `parseSearchLines`, which sorts on the trailing key. The two parsers are separate because search needs an ordering the unread path doesn't; `parseEmailLines(includeReadField: true)` is now reached only from tests. If you add a field, update the emitter and its parser together.
- **`search` never emits a body.** The preview is left empty on purpose: the old script fetched `content of msg` per result and then truncated it to 300 chars, paying a full per-message round trip to keep a snippet. Callers wanting a body call `getMessage`.
- **Sanitising is `text item delimiters`, not `do shell script`.** The old sanitiser forked a subprocess per field per message (7 per result). Don't reintroduce a shell-out in a per-message loop.
- **Sendability.** Public types are `Sendable`. `MailService` must not capture non-Sendable state; if you add dependencies, make them `Sendable` or wrap them the way `NSAppleScriptRunner` wraps `NSAppleScript`.
- **String escaping.** Anything the caller supplies that ends up inside an AppleScript string literal (account, mailbox, query, message id, to/cc/bcc, subject) goes through `escapeForAppleScript`, which doubles backslashes *first* and then escapes `"` as `\"`. Escaping only the quotes lets a value ending in `\` break out of the literal and run as AppleScript. Multi-line email bodies in `send` avoid the problem entirely by being written to a temp file and read back via `read file POSIX file "…" as «class utf8»`. Keep that pattern for anything new that might contain newlines or quotes.
- **Search backend selection.** `search` tries, in order: the Envelope Index (`MailIndexReader`, when Full Disk Access allowed it to open); Spotlight (only when unscoped — it can't express Mail's account/mailbox grouping); then AppleScript. An index *query* error (`MailIndexReaderError`: a schema change, a lock outlasting the busy timeout) is logged and falls through to the next backend — on the first page only (`offset == 0`; same for `getUnread`); on a later page it is thrown, because page 1 came from the index. A timeout never falls through. `forceBackend: .spotlight` skips the AppleScript fallback even on empty results, and throws `tooBroad` when no Spotlight backend is configured; `forceBackend: .index` surfaces index errors. Don't collapse this — every constraint matters.
- **The index reader never writes Mail's store.** Each query opens its own handle read-write (a read-only handle can't open a WAL-mode store whose `-wal` Mail removed on a clean quit) with `PRAGMA query_only = 1`, a 2s busy timeout, and `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` — `query_only` alone doesn't stop the checkpoint SQLite runs when the last connection closes, which would fold Mail's WAL into its database file. Failing to set either guard is fatal.
- **Handlers live outside `with timeout`.** `MailTimeouts.bound` wraps a script's top-level statements and moves `on name(…)` handler definitions after `end timeout`; AppleScript won't compile a handler defined inside the block. Unit tests only see generated text, so check a changed script with `osacompile` before trusting it.
- **Unscoped AppleScript results still name their account.** The search, unread and get scripts walk accounts, then each account's mailboxes, so `acctName` comes from `name of a`. Never resolve it per mailbox with `first account whose mailboxes contains m`.
- **Every page of a query comes from the same backend.** Spotlight pages by requesting `offset + limit` and dropping the first `offset` after its global sort; it falls back to AppleScript only when it has no hit at all, which is true of every page alike. Likewise the index falls back on an error only for `offset == 0`; page 2+ throws instead of being answered by Spotlight/AppleScript. Letting page 2+ drop to AppleScript (subject-or-sender match, mailbox-order skip) while page 1 came from Spotlight (subject-or-body, global sort) skipped and duplicated mail across pages.
- **Message-IDs are bare.** Mail's AppleScript `message id` has no angle brackets; the index stores `<…>`. `MailService.normalizeMessageID` is the one place ids are shaped — the index emits through it and `getMessageScript` looks up through it.
- **A queued script whose caller is gone is dropped; a started send is awaited.** `NSAppleScriptRunner` checks cancellation inside the main-thread hop, so a timed-out call never runs late and backs up the main actor. `send` bounds only the wait for its script to *start* (`ScriptStartGate`): `timedOut` from `send` therefore means "never handed to Mail — retry is safe". Don't wrap a started send in a Swift timer again; that reported `timedOut` for mail Mail then delivered, and retries sent it twice.
- **Every backend returns newest-first — globally on index and Spotlight, per-page on AppleScript.** The index sorts in SQL and Spotlight sorts parsed `kMDItemContentCreationDate`, both *before* applying `limit`, so they return the newest matches overall. The AppleScript path can't: sorting globally there means resolving every match, which is the 154s cost. It stops at `limit` in Mail's mailbox-iteration order and sorts that page, so with more matches than `limit` it returns the newest of whichever mailboxes Mail walked first. Don't paper over the distinction in docs — but if you add a backend that *can* see all matches, sort before you truncate.
- **The same argument must mean the same thing on every backend.** `sinceDaysAgo <= 0` means "no date bound" everywhere; the AppleScript path omits the cutoff entirely rather than computing `now - 0 days`, which would match nothing. Watch for this whenever a parameter is implemented separately per backend.
- **An incomplete scan must never look like a complete one.** Spotlight's 8MB output cap throws `tooBroad` when hit rather than ranking the survivors, for the same reason `timedOut` exists.
- **A timeout is never an empty result.** `MailServiceError.timedOut` exists because an Apple Event timeout used to be caught by a per-mailbox `try`, leaving the script to return `""` and the caller to read it as "no matching mail". Don't add a `try` around a `whose` clause, and don't map any error to `[]`.
- **Mail's `whose` cost scales with matches, not with `limit`.** A `count of` costs the same as fetching, so there is no cheap pre-check. Measured on a 275,422-message Gmail mailbox: 0 matches 0.5s, 18 matches 23.7s, 153 matches 154s. This is why the index is the primary backend rather than an optimisation, and why no amount of tuning makes the AppleScript path fast.
- **Limits are capped at 100** internally (`cappedLimit`, `min(limit, 100)`), with `offset` pagination to page beyond the cap. This is a deliberate guard against runaway Mail.app iteration on Gmail-heavy setups where each label is a separate mailbox (originally 20; raised to 100 when `offset` landed so a single page can be useful, but still bounded — don't remove the cap without thinking about why it's there). Non-positive limits return `[]` without running any script.

**Testing conventions:**

- This project uses Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest.
- Unit tests drive `MailService` via `FakeAppleScriptRunner` (queues scripted responses, records every `source` passed to `run`). Use the recorded `calls[n]` to assert that generated AppleScript contains the expected scoping/escaping — that's how we cover script generation without hitting Mail.
- `SpotlightMailSearch` takes a `Runner` closure; tests inject a fake and assert on the `mdfind` argv. For launch-failure paths there's also `SpotlightMailSearch.makeProcessRunner(executableURL:)` — a testability seam, not a public extension point; don't use it from production code.
- `NSAppleScriptRunnerTests` is `@Suite(.serialized)`. AppleScript's component manager has process-global state that interleaves error reporting across concurrent executions; parallel execution produces confusing cross-test failures. Leave the serialization in place.
- Follow TDD — there are existing tests for every behavior in `MailService.parseEmailLines`, backend selection, and input validation. New behavior should land with a failing test first.

**Coverage baseline:** The suite sits at ~98% line / ~90% region coverage. The remaining uncovered code is documented defensive fallbacks around Apple-API edge cases that can't be reliably provoked from tests (`NSAppleScript(source:)` returning nil, `errorInfo` without `errorMessage`/`errorBriefMessage` keys, lazy `log.debug { }` closures). Don't refactor production code to chase these — the fallbacks exist precisely because those edge cases are real but rare.

<!-- pr-workflow:v3 -->
## Pull requests & release notes

Fleet policy — Conventional-Commit PR titles, labels, the auto-review /
auto-merge ladder, auto-review follow-up issues, PR timing, and release PRs —
lives in `~/.claude/CLAUDE.md`. Don't restate it here; the copies drifted.

Shared technical conventions (publishing, bundling, versioning guards,
write-verification, transport archetypes, testing traps) live in
[`chrischall/workflows`](https://github.com/chrischall/workflows):
`docs/fleet-conventions.md`, plus `README.md` for the CI pipeline contract.

