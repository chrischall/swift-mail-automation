# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Swift Package Manager project, macOS 14+, Swift 6 with strict concurrency.

```bash
swift build               # build the library
swift build -c release    # release build (mirrors the Release workflow)
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

This is a **local Mail.app wrapper**, not a mail client. No IMAP/SMTP — every read/write goes through AppleScript against the running Mail.app, with Spotlight as a fast path for content search.

**Layering (Sources/MailAutomation/):**

- `MailService` — the single public entry point. Builds AppleScript source strings, dispatches them through an injected `AppleScriptRunner`, and parses tab-delimited results via `parseEmailLines`. Owns the Spotlight-vs-AppleScript decision for `search`.
- `AppleScriptRunner` (protocol) + `NSAppleScriptRunner` (production impl). The production impl constructs and runs the script entirely inside a hop to the **main thread** (`NSAppleScriptRunner.onMainThread(_:)`, backed by `MainActor.run`). That keeps the non-`Sendable` `NSAppleScript` lifecycle on one thread *and* is load-bearing for correctness: a script targeting another app waits for its Apple Event reply inside Carbon's `AEDefaultActiveProc`, which pumps only the main thread's event queue — where the reply is delivered. Run off the main thread it stalls (~32s on one measurement, no return before a 200s timeout on another) with no error and no timeout. Do not move this back to a detached `Task`. Tests inject a fake instead.
- `SpotlightMailSearch` — subprocesses `/usr/bin/mdfind` against `~/Library/Mail`. Chose `mdfind` over `NSMetadataQuery` because the latter needs a RunLoop and fights Swift 6 strict concurrency. The `Runner` typealias lets tests inject a fake process runner.
- `EmailMessage`, `ISODate`, `StringHelpers` — value types / shared helpers. All public types are `Sendable`.

**Key invariants to preserve when editing:**

- **AppleScript output shape.** `getUnread` emits 7 tab-separated fields per line (`subject, sender, date, mailbox, account, body, messageId`) and parses through `parseEmailLines`. `search` emits 9 (`subject, sender, date, mailbox, account, isRead, body, messageId, sortKey`) and parses through `parseSearchLines`, which sorts on the trailing key. The two parsers are separate because search needs an ordering the unread path doesn't; `parseEmailLines(includeReadField: true)` is now reached only from tests. If you add a field, update the emitter and its parser together.
- **`search` never emits a body.** The preview is left empty on purpose: the old script fetched `content of msg` per result and then truncated it to 300 chars, paying a full per-message round trip to keep a snippet. Callers wanting a body call `getMessage`.
- **Sanitising is `text item delimiters`, not `do shell script`.** The old sanitiser forked a subprocess per field per message (7 per result). Don't reintroduce a shell-out in a per-message loop.
- **Sendability.** Public types are `Sendable`. `MailService` must not capture non-Sendable state; if you add dependencies, make them `Sendable` or wrap them the way `NSAppleScriptRunner` wraps `NSAppleScript`.
- **String escaping.** Anything the caller supplies that ends up inside an AppleScript string literal (account, mailbox, query, to/cc/bcc, subject) is escaped by replacing `"` with `\"`. Multi-line email bodies in `send` avoid the problem entirely by being written to a temp file and read back via `read file POSIX file "…" as «class utf8»`. Keep that pattern for anything new that might contain newlines or quotes.
- **Search backend selection.** `search` tries, in order: the Envelope Index (`MailIndexReader`, when Full Disk Access allowed it to open); Spotlight (only when unscoped and un-paged — it can't express Mail's account/mailbox grouping and can't page); then AppleScript. `forceBackend: .spotlight` skips the AppleScript fallback even on empty results. Don't collapse this — every constraint matters.
- **Every backend returns newest-first.** The index sorts in SQL, the AppleScript path sorts on an emitted sort key, and Spotlight sorts parsed `kMDItemContentCreationDate` **before** applying `limit`. Truncating in a backend's native order silently drops newer matches in favour of older ones — that was a real bug in all three paths. If you add a backend, sort before you truncate.
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

