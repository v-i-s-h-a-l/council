@testable import CouncilCLI
import CouncilCore
import Foundation
import Testing

/// Adversarial tests for confidential-data boundaries in `ProfileCommand`.
@Suite("ProfileCommand adversarial")
struct ProfileCommandAdversarialTests {

    @Test("profile show output never contains confidential journal or financial text")
    func profileShowOutputNeverContainsConfidentialText() throws {
        let journalSecret = "JOURNAL_SECRET_MARKER_9f3"
        let financialSecret = "FINANCIAL_SECRET_MARKER_7d1"
        let profile = UserProfile(
            values: [ValueStatement(text: "Be frugal")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: [financialSecret]),
            journalEntries: [JournalEntry(text: journalSecret)]
        )

        // Text output: routable items render in full, confidential containers
        // contribute only their counts.
        let text = formatProfileShowText(profile)
        #expect(!text.contains(journalSecret))
        #expect(!text.contains(financialSecret))
        #expect(text.contains("Be frugal"))
        #expect(text.contains("Journal: 1 confidential entry"))
        #expect(text.contains("Financial: 1 confidential record"))

        // JSON output: RoutableProfileContext must not carry the containers
        // or their contents onto the wire at all.
        let json = try CLIEncoder.json(RoutableProfileContext(profile: profile))
        #expect(!json.contains(journalSecret))
        #expect(!json.contains(financialSecret))
        #expect(!json.contains("journalEntries"))
        #expect(!json.contains("financialHistory"))
    }

    @Test("journal add rejects empty and whitespace-only bodies")
    func journalAddRejectsWhitespaceOnlyBody() throws {
        #expect(throws: (any Error).self) {
            try validatedJournalBody("")
        }
        #expect(throws: (any Error).self) {
            try validatedJournalBody("  \n\t \n")
        }
        // Real content passes unchanged, padding included.
        #expect(try validatedJournalBody("  real entry  ") == "  real entry  ")
        #expect(try validatedJournalBody("line one\nline two\n") == "line one\nline two\n")
    }

    @Test("journal dates accept fractional seconds like audit list --since")
    func journalListAcceptsFractionalSecondsLikeAuditList() throws {
        // Parity pin: the same timestamp string must parse for both commands.
        let fractional = try parseISODate("2026-07-09T12:00:00.500Z")
        #expect(fractional.timeIntervalSince1970 == 1_783_598_400.5)

        let plain = try parseISODate("2026-07-09T12:00:00Z")
        #expect(plain.timeIntervalSince1970 == 1_783_598_400)

        #expect(throws: (any Error).self) {
            try parseISODate("not-a-date")
        }
    }

    @Test("journal list rejects a negative --limit, pins zero")
    func journalListNegativeAndZeroLimit() throws {
        // `entries.prefix(-1)` silently returns nothing, which then prints the
        // misleading "No journal entries." even though entries exist.
        #expect(throws: (any Error).self) {
            try ProfileCommand.JournalCommand.ListCommand.parse(["--limit", "-1"])
        }

        let zero = try ProfileCommand.JournalCommand.ListCommand.parse(["--limit", "0"])
        #expect(zero.limit == 0)
        let ten = try ProfileCommand.JournalCommand.ListCommand.parse(["--limit", "10"])
        #expect(ten.limit == 10)
    }
}
