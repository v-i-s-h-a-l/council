import Foundation
import Testing
@testable import CouncilCore

/// Adversarial coverage for the privacy boundary between `UserProfile`
/// (device-only, confidential) and `RoutableProfileContext` (may reach a model
/// prompt), plus the PBAC scope invariants that keep them apart.
struct ProfilePrivacyAdversarialTests {

    // MARK: - A7: the serialized routable context must not leak confidential data

    @Test func routableContextEncodedJSONContainsNoConfidentialKeysOrValues() throws {
        let profile = UserProfile(
            values: [ValueStatement(text: "Frugality")],
            goals: [Goal(text: "Save for travel")],
            boundaries: [Boundary(text: "No impulse buys")],
            financialHistory: ClientConfidentialContainer(items: ["CANARY-FIN-9000 salary"]),
            journalEntries: [JournalEntry(text: "CANARY-JOURNAL-042 dream vacation")]
        )

        let context = RoutableProfileContext(profile: profile)
        let encoded = try JSONEncoder().encode(context)
        let json = String(decoding: encoded, as: UTF8.self)

        // Guard the actual serialization boundary: if a confidential field is
        // ever added to RoutableProfileContext, this fails before it reaches a
        // model prompt.
        #expect(!json.contains("CANARY-FIN-9000"))
        #expect(!json.contains("CANARY-JOURNAL-042"))
        #expect(!json.contains("financialHistory"))
        #expect(!json.contains("journalEntries"))
        #expect(!json.contains("journalExcerpts"))
        #expect(json.contains("Frugality"))
    }

    // MARK: - A8: legacy journalExcerpts migration

    @Test func legacyJournalExcerptsMigrateToUserInspectionOnly() throws {
        let json = """
        {
            "values": [],
            "journalExcerpts": {"items": ["CANARY-EXCERPT-1", "CANARY-EXCERPT-2"]}
        }
        """
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))

        #expect(profile.journalEntries.count == 2)
        for entry in profile.journalEntries {
            // The migration is the only thing keeping old installs' private
            // journals out of model-routable scope — exactly userInspection,
            // never allDeliberation.
            #expect(entry.accessScope == [.userInspection])
        }
        #expect(profile.journalEntries.map(\.text).contains("CANARY-EXCERPT-1"))
        #expect(profile.journalEntries.map(\.text).contains("CANARY-EXCERPT-2"))
    }

    @Test func structuredJournalEntriesWinOverLegacyExcerpts() throws {
        let json = """
        {
            "journalEntries": [
                {
                    "id": "00000000-0000-0000-0000-0000000000AA",
                    "text": "structured entry",
                    "createdAt": 700000000,
                    "tags": ["tag"],
                    "accessScope": ["userInspection"],
                    "isLocked": true
                }
            ],
            "journalExcerpts": {"items": ["legacy excerpt must be dropped"]}
        }
        """
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))

        #expect(profile.journalEntries.count == 1)
        #expect(profile.journalEntries[0].text == "structured entry")
        #expect(profile.journalEntries[0].isLocked)
        #expect(profile.journalEntries[0].tags == ["tag"])
    }

    // MARK: - A9: PBAC keystone invariant

    @Test func allDeliberationExcludesUserInspectionAndCoversAllCases() {
        // If userInspection ever joins allDeliberation, every pre-PBAC legacy
        // value/goal/boundary decodes into user-inspection scope and vice versa.
        #expect(!AccessPurpose.allDeliberation.contains(.userInspection))
        #expect(Set(AccessPurpose.allDeliberation + [.userInspection]) == Set(AccessPurpose.allCases))
    }

    // MARK: - A13: full-fidelity profile round-trip

    @Test func userProfileRoundTripPreservesAllFieldsIncludingConfidential() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let unicodeText = "Säve 🎉 \"quoted\" text\nwith newline\ttab — 日本語"
        let profile = UserProfile(
            values: [ValueStatement(
                text: unicodeText,
                createdAt: createdAt,
                tags: ["t1", "t2"],
                accessScope: [.purchaseDeliberation],
                deniedPurposes: [.travelDeliberation]
            )],
            goals: [Goal(
                text: "Retire early",
                timeframe: "2040",
                createdAt: createdAt,
                tags: [],
                status: .active,
                accessScope: [.lifeDeliberation],
                deniedPurposes: [.purchaseDeliberation]
            )],
            boundaries: [Boundary(
                text: "Never share location",
                createdAt: createdAt,
                tags: ["privacy"],
                severity: .critical,
                accessScope: AccessPurpose.allDeliberation,
                deniedPurposes: []
            )],
            financialHistory: ClientConfidentialContainer(items: ["income: 42"]),
            journalEntries: [JournalEntry(
                text: unicodeText,
                createdAt: createdAt,
                tags: ["j"],
                accessScope: [.userInspection],
                isLocked: true
            )]
        )

        let encoded = try JSONEncoder().encode(profile)
        let json = String(decoding: encoded, as: UTF8.self)
        // The legacy key must not round-trip back into existence on encode.
        #expect(!json.contains("journalExcerpts"))

        let decoded = try JSONDecoder().decode(UserProfile.self, from: encoded)

        #expect(decoded.values.count == 1)
        #expect(decoded.values[0].id == profile.values[0].id)
        #expect(decoded.values[0].text == unicodeText)
        #expect(decoded.values[0].createdAt == createdAt)
        #expect(decoded.values[0].tags == ["t1", "t2"])
        #expect(decoded.values[0].accessScope == [.purchaseDeliberation])
        #expect(decoded.values[0].deniedPurposes == [.travelDeliberation])

        #expect(decoded.goals.count == 1)
        #expect(decoded.goals[0].timeframe == "2040")
        #expect(decoded.goals[0].status == .active)
        #expect(decoded.goals[0].accessScope == [.lifeDeliberation])
        #expect(decoded.goals[0].deniedPurposes == [.purchaseDeliberation])

        #expect(decoded.boundaries.count == 1)
        #expect(decoded.boundaries[0].severity == .critical)
        #expect(decoded.boundaries[0].tags == ["privacy"])

        #expect(decoded.financialHistory.items == ["income: 42"])

        #expect(decoded.journalEntries.count == 1)
        #expect(decoded.journalEntries[0].id == profile.journalEntries[0].id)
        #expect(decoded.journalEntries[0].text == unicodeText)
        #expect(decoded.journalEntries[0].accessScope == [.userInspection])
        #expect(decoded.journalEntries[0].isLocked)
    }
}
