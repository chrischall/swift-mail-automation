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
- `AppleScriptRunner` (protocol) + `NSAppleScriptRunner` (production impl). `NSAppleScript` isn't `Sendable`, so the production impl constructs and runs the script entirely inside a detached `Task` to keep its lifecycle on one thread. Tests inject a fake instead.
- `SpotlightMailSearch` — subprocesses `/usr/bin/mdfind` against `~/Library/Mail`. Chose `mdfind` over `NSMetadataQuery` because the latter needs a RunLoop and fights Swift 6 strict concurrency. The `Runner` typealias lets tests inject a fake process runner.
- `EmailMessage`, `ISODate`, `StringHelpers` — value types / shared helpers. All public types are `Sendable`.

**Key invariants to preserve when editing:**

- **AppleScript output shape.** `getUnread` emits 6 tab-separated fields per line (`subject, sender, date, mailbox, account, body`); `search` emits 7 (inserts `isRead` before `body`). `parseEmailLines` is shared between both paths and keyed on `includeReadField`. If you add a field, update both sides.
- **Sendability.** Public types are `Sendable`. `MailService` must not capture non-Sendable state; if you add dependencies, make them `Sendable` or wrap them the way `NSAppleScriptRunner` wraps `NSAppleScript`.
- **String escaping.** Anything the caller supplies that ends up inside an AppleScript string literal (account, mailbox, query, to/cc/bcc, subject) is escaped by replacing `"` with `\"`. Multi-line email bodies in `send` avoid the problem entirely by being written to a temp file and read back via `read file POSIX file "…" as «class utf8»`. Keep that pattern for anything new that might contain newlines or quotes.
- **Search backend selection.** `search` picks the backend automatically: Spotlight when `spotlight != nil` and no account/mailbox scope was supplied (Spotlight can't scope by Mail's account/mailbox grouping); AppleScript otherwise. `forceBackend: .spotlight` skips the AppleScript fallback even on empty results. Don't collapse this — both constraints matter.
- **Limits are capped at 20** internally (`min(limit, 20)`). This is a deliberate guard against runaway Mail.app iteration on Gmail-heavy setups where each label is a separate mailbox; don't remove without thinking about why it's there.

**Testing conventions:**

- This project uses Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest.
- Unit tests drive `MailService` via `FakeAppleScriptRunner` (queues scripted responses, records every `source` passed to `run`). Use the recorded `calls[n]` to assert that generated AppleScript contains the expected scoping/escaping — that's how we cover script generation without hitting Mail.
- `SpotlightMailSearch` takes a `Runner` closure; tests inject a fake and assert on the `mdfind` argv. For launch-failure paths there's also `SpotlightMailSearch.makeProcessRunner(executableURL:)` — a testability seam, not a public extension point; don't use it from production code.
- `NSAppleScriptRunnerTests` is `@Suite(.serialized)`. AppleScript's component manager has process-global state that interleaves error reporting across concurrent executions; parallel execution produces confusing cross-test failures. Leave the serialization in place.
- Follow TDD — there are existing tests for every behavior in `MailService.parseEmailLines`, backend selection, and input validation. New behavior should land with a failing test first.

**Coverage baseline:** The suite sits at ~98% line / ~90% region coverage. The remaining uncovered code is documented defensive fallbacks around Apple-API edge cases that can't be reliably provoked from tests (`NSAppleScript(source:)` returning nil, `errorInfo` without `errorMessage`/`errorBriefMessage` keys, lazy `log.debug { }` closures). Don't refactor production code to chase these — the fallbacks exist precisely because those edge cases are real but rare.

<!-- pr-workflow:v1 -->
## Pull requests & release notes

**Default workflow: branch + PR, even for solo work.** Direct pushes to `main` skip review *and* skip auto-generated release notes — GitHub's `generate_release_notes` (configured in `.github/release.yml`) only picks up merged PRs. Push directly to `main` only when the user explicitly asks for it (e.g. emergency hotfix).

For every PR, apply exactly one label so it lands in the right release-notes section:

| Label                | Section in release notes |
|----------------------|--------------------------|
| `enhancement`        | Features                 |
| `bug`                | Bug Fixes                |
| `security`           | Security                 |
| `refactor`           | Refactor                 |
| `documentation`      | Documentation            |
| `test`               | Tests                    |
| `dependencies`       | Dependencies             |
| `ci` / `github_actions` | CI & Build            |
| *(none / unmatched)* | Other Changes            |
| `ignore-for-release` | Hidden from notes        |

The **PR title** becomes the bullet — write it like a user-facing changelog entry, not internal shorthand. Conventional-commit prefixes are still fine in commit messages, but the PR title should read clean.

Open with `gh pr create --label <label>` (or `--label ignore-for-release` for chores not worth a line), then **immediately** run `gh pr merge <num> --auto --merge` so the PR merges as soon as CI passes. The repo allows merge commits only (no squash, no rebase) — don't pass `--squash`/`--rebase` or the call will fail.
