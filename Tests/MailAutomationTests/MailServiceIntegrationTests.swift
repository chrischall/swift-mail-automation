import Foundation
@testable import MailAutomation
import Testing

/// End-to-end tests against the user's real Mail.app.
///
/// All tests are opt-in via env vars — unset, they're skipped, so CI
/// stays deterministic and users don't get surprise permission prompts.
///
/// Environment variables:
///
/// - `MAIL_AUTOMATION_INTEGRATION=1` — enables the read-only tests
///   (`listAccounts`, `listMailboxes`, `getUnread`). These don't mutate
///   anything but require **Automation** permission on Mail for the
///   test binary.
///
/// - `MAIL_AUTOMATION_SEND_TO=you@example.com` — enables the send
///   round-trip test. Should be an address **you control** (your own
///   inbox, or a noreply you own). Sending to a stranger is rude and
///   we won't do it. The test sends a single tagged message with
///   `[MailAutomation-SelfTest]` in the subject.
///
/// ```bash
/// # Read-only
/// MAIL_AUTOMATION_INTEGRATION=1 swift test
///
/// # With send round-trip (to your own address)
/// MAIL_AUTOMATION_INTEGRATION=1 \
///   MAIL_AUTOMATION_SEND_TO=me@example.com \
///   swift test
/// ```
@Suite("MailService integration")
struct MailServiceIntegrationTests {
    private static let readOnlyEnabled =
        ProcessInfo.processInfo.environment["MAIL_AUTOMATION_INTEGRATION"] == "1"

    private static let sendTo =
        ProcessInfo.processInfo.environment["MAIL_AUTOMATION_SEND_TO"]
            .flatMap { $0.isEmpty ? nil : $0 }

    // MARK: - Read-only smoke

    @Test("listAccounts returns at least one account",
          .disabled(if: ProcessInfo.processInfo.environment["MAIL_AUTOMATION_INTEGRATION"] != "1",
                    "set MAIL_AUTOMATION_INTEGRATION=1"))
    func listAccountsSmokes() async throws {
        let svc = MailService(runner: NSAppleScriptRunner())
        let accounts = try await svc.listAccounts()
        // Anyone running this test presumably has Mail configured with
        // at least one account. We don't assert on names — they're
        // user-specific.
        #expect(!accounts.isEmpty, "no Mail accounts configured — open Mail.app and add one")
    }

    @Test("listMailboxes returns at least an inbox for the first account",
          .disabled(if: ProcessInfo.processInfo.environment["MAIL_AUTOMATION_INTEGRATION"] != "1",
                    "set MAIL_AUTOMATION_INTEGRATION=1"))
    func listMailboxesSmokes() async throws {
        let svc = MailService(runner: NSAppleScriptRunner())
        let accounts = try await svc.listAccounts()
        guard let first = accounts.first else {
            Issue.record("listAccounts returned empty; can't test mailboxes")
            return
        }
        let boxes = try await svc.listMailboxes(account: first)
        #expect(!boxes.isEmpty, "account \"\(first)\" has no mailboxes?")
        // Most providers have at least one of these names
        let hasInboxLike = boxes.contains(where: { ["INBOX", "Inbox"].contains($0) })
        #expect(hasInboxLike, "no INBOX/Inbox in \(boxes)")
    }

    @Test("getUnread returns a well-shaped array",
          .disabled(if: ProcessInfo.processInfo.environment["MAIL_AUTOMATION_INTEGRATION"] != "1",
                    "set MAIL_AUTOMATION_INTEGRATION=1"))
    func getUnreadSmokes() async throws {
        let svc = MailService(runner: NSAppleScriptRunner())
        let unread = try await svc.getUnread(limit: 3)
        // May be zero if the user has an empty unread pile — just
        // validate shape.
        for m in unread {
            #expect(m.isRead == false)
            #expect(!m.mailbox.isEmpty)
        }
    }

    // MARK: - Send round-trip

    /// Send to an address the user explicitly opted in to via
    /// `MAIL_AUTOMATION_SEND_TO`. We never send to a stranger. The test
    /// subject is tagged so you can find and delete the message later:
    /// `[MailAutomation-SelfTest] <uuid>`.
    @Test("send dispatches through Mail.app and returns without error",
          .disabled(if: !(ProcessInfo.processInfo.environment["MAIL_AUTOMATION_INTEGRATION"] == "1"
                        && (ProcessInfo.processInfo.environment["MAIL_AUTOMATION_SEND_TO"]?.isEmpty == false)),
          "set MAIL_AUTOMATION_INTEGRATION=1 and MAIL_AUTOMATION_SEND_TO=<your address>"))
    func sendToSelf() async throws {
        guard let destination = Self.sendTo else {
            // Guard is redundant with the .disabled trait above but makes
            // the body type-check cleanly against an optional.
            return
        }
        let svc = MailService(runner: NSAppleScriptRunner())
        let tag = UUID().uuidString.prefix(8)
        try await svc.send(
            to: destination,
            subject: "[MailAutomation-SelfTest] \(tag)",
            body: "Automated self-test from MailAutomation (run \(tag)). Safe to delete."
        )
        // If we got here without throwing, Mail accepted the send.
        // Actual delivery depends on the destination — we don't poll
        // the recipient to verify, since that would require mailbox
        // access we can't assume.
    }
}
