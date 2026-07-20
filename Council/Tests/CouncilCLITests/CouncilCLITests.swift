import ArgumentParser
import CouncilAgents
@testable import CouncilCLI
import CouncilCore
import CouncilInference
import CouncilMemory
import CouncilTestUtilities
import Foundation
import Testing

@Suite("CouncilCLI")
struct CouncilCLITests {

    @Test("ask command parses required question")
    func parsesQuestion() throws {
        let command = try AskCommand.parse(["Should I buy this?"])
        #expect(command.question == "Should I buy this?")
        #expect(command.provider == .echo)
        #expect(command.options.format == .text)
        #expect(!command.consentDownload)
    }

    @Test("ask command parses options")
    func parsesOptions() throws {
        let checksum = "sha256:" + String(repeating: "ab", count: 32)
        let command = try AskCommand.parse([
            "--provider", "mlx",
            "--model", "mlx-community/test",
            "--checksum", checksum,
            "--consent-download",
            "--format", "json",
            "--profile-dir", "/tmp/council-test",
            "--verbose",
            "--no-persist",
            "Should I buy this?",
        ])
        #expect(command.provider == .mlx)
        #expect(command.model == "mlx-community/test")
        #expect(command.checksum == checksum)
        #expect(command.consentDownload)
        #expect(command.options.format == .json)
        #expect(command.options.profileDir == "/tmp/council-test")
        #expect(command.options.verbose)
        #expect(command.noPersist)
    }

    @Test("mlx provider requires --model")
    func mlxRequiresModel() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx",
                "--checksum", "sha256:deadbeef",
                "Should I buy this?",
            ])
        }
    }

    @Test("mlx provider requires --checksum")
    func mlxRequiresChecksum() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse([
                "--provider", "mlx",
                "--model", "mlx-community/test",
                "Should I buy this?",
            ])
        }
    }

    @Test("invalid provider is rejected")
    func rejectsInvalidProvider() {
        #expect(throws: (any Error).self) {
            try AskCommand.parse(["--provider", "invalid", "Should I buy this?"])
        }
    }

    @Test("perspective formatter produces ordered, correctly labeled text output")
    func textFormatter() {
        let perspective = Perspective(
            summary: "Summary text.",
            tradeOffs: ["Trade-off one."],
            blindSpots: ["Blind spot one."],
            dissent: ["Dissent one."]
        )
        let output = PerspectiveFormatter.text(perspective)
        // Each header must be immediately followed by its own content, in the
        // canonical section order: swapped or mislabeled sections fail here,
        // not just missing ones.
        guard let summary = output.range(of: "Summary\n-------\nSummary text."),
              let tradeOffs = output.range(of: "Trade-offs\n----------\n• Trade-off one."),
              let blindSpots = output.range(of: "Blind spots\n-----------\n• Blind spot one."),
              let dissent = output.range(of: "Dissent\n-------\n• Dissent one.") else {
            Issue.record("Missing or malformed section in formatter output:\n\(output)")
            return
        }
        #expect(summary.lowerBound < tradeOffs.lowerBound)
        #expect(tradeOffs.lowerBound < blindSpots.lowerBound)
        #expect(blindSpots.lowerBound < dissent.lowerBound)
    }

    @Test("MemoryService records episode and appends audit")
    func memoryServiceOperations() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        let sessionID = UUID()
        let perspective = Perspective(summary: "Test.")
        try await service.recordEpisode(
            sessionID: sessionID,
            question: "Should I test?",
            perspective: perspective
        )
        try await service.appendAuditEntry(
            category: .sessionStarted,
            sessionID: sessionID,
            payload: ["question": "Should I test?"]
        )

        let episodes = try await service.recentEpisodes()
        #expect(episodes.count == 1)
        #expect(episodes.first?.question == "Should I test?")

        let auditEntries = await auditLog.entries
        #expect(auditEntries.count == 1)
        #expect(auditEntries.first?.category == .sessionStarted)
    }

    // MARK: - New command parsing

    @Test("profile value add parses")
    func profileValueAddParses() throws {
        let command = try ProfileCommand.ValueCommand.AddCommand.parse(["Be frugal"])
        #expect(command.text == "Be frugal")
    }

    @Test("profile value remove parses UUID")
    func profileValueRemoveParses() throws {
        let id = UUID()
        let command = try ProfileCommand.ValueCommand.RemoveCommand.parse([id.uuidString])
        #expect(command.id == id)
    }

    @Test("memory list parses limit")
    func memoryListParses() throws {
        let command = try MemoryCommand.ListCommand.parse(["--limit", "10"])
        #expect(command.limit == 10)
    }

    @Test("memory fact add parses purpose")
    func memoryFactAddParses() throws {
        let command = try MemoryCommand.FactCommand.AddCommand.parse([
            "user", "budget", "1000", "--purpose", "purchaseDeliberation",
        ])
        #expect(command.subject == "user")
        #expect(command.predicate == "budget")
        #expect(command.object == "1000")
        #expect(command.purpose == .purchaseDeliberation)
    }

    @Test("model register parses checksum")
    func modelRegisterParses() throws {
        let checksum = "sha256:" + String(repeating: "cd", count: 32)
        let command = try ModelCommand.RegisterCommand.parse([
            "mlx-community/test", "--checksum", checksum,
        ])
        #expect(command.id == "mlx-community/test")
        #expect(command.checksum == checksum)
    }

    @Test("audit list parses include-payloads")
    func auditListParses() throws {
        let command = try AuditCommand.ListCommand.parse(["--include-payloads", "--limit", "5"])
        #expect(command.includePayloads)
        #expect(command.limit == 5)
    }

    // MARK: - Service additions

    @Test("ProfileService adds and removes values")
    func profileServiceValueManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let value = try await service.addValue("Be mindful")
        #expect(value.text == "Be mindful")

        var profile = try await service.load()
        #expect(profile.values.count == 1)

        try await service.removeValue(id: value.id)
        profile = try await service.load()
        #expect(profile.values.isEmpty)
    }

    @Test("ProfileService adds and removes goals")
    func profileServiceGoalManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let goal = try await service.addGoal("Save for travel", timeframe: "2027")
        #expect(goal.timeframe == "2027")

        try await service.removeGoal(id: goal.id)
        let profile = try await service.load()
        #expect(profile.goals.isEmpty)
    }

    @Test("ProfileService adds and removes boundaries")
    func profileServiceBoundaryManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let boundary = try await service.addBoundary("No impulse buys")
        #expect(boundary.text == "No impulse buys")

        try await service.removeBoundary(id: boundary.id)
        let profile = try await service.load()
        #expect(profile.boundaries.isEmpty)
    }

    @Test("profile value add parses with tags")
    func profileValueAddParsesWithTags() throws {
        let command = try ProfileCommand.ValueCommand.AddCommand.parse(["Be frugal", "--tag", "finance", "--tag", "habit"])
        #expect(command.text == "Be frugal")
        #expect(command.tag == ["finance", "habit"])
    }

    @Test("profile goal add parses with tags and status")
    func profileGoalAddParsesWithTagsAndStatus() throws {
        let command = try ProfileCommand.GoalCommand.AddCommand.parse([
            "Save for travel", "--timeframe", "2027", "--tag", "finance", "--status", "active",
        ])
        #expect(command.text == "Save for travel")
        #expect(command.timeframe == "2027")
        #expect(command.tag == ["finance"])
        #expect(command.status == .active)
    }

    @Test("profile boundary add parses with severity")
    func profileBoundaryAddParsesWithSeverity() throws {
        let command = try ProfileCommand.BoundaryCommand.AddCommand.parse([
            "No impulse buys", "--severity", "high", "--tag", "spending",
        ])
        #expect(command.text == "No impulse buys")
        #expect(command.severity == .high)
        #expect(command.tag == ["spending"])
    }

    @Test("profile journal add parses")
    func profileJournalAddParses() throws {
        let command = try ProfileCommand.JournalCommand.AddCommand.parse(["Feeling reflective", "--tag", "evening"])
        #expect(command.text == "Feeling reflective")
        #expect(command.tag == ["evening"])
    }

    @Test("profile journal add parses with stdin flag")
    func profileJournalAddParsesStdin() throws {
        let command = try ProfileCommand.JournalCommand.AddCommand.parse(["--stdin", "--tag", "morning"])
        #expect(command.stdin)
        #expect(command.text == nil)
        #expect(command.tag == ["morning"])
    }

    @Test("profile journal add parses with date")
    func profileJournalAddParsesDate() throws {
        let command = try ProfileCommand.JournalCommand.AddCommand.parse([
            "Retro", "--date", "2026-07-09T12:00:00Z",
        ])
        #expect(command.text == "Retro")
        #expect(command.date == "2026-07-09T12:00:00Z")
    }

    @Test("profile journal list parses")
    func profileJournalListParses() throws {
        let command = try ProfileCommand.JournalCommand.ListCommand.parse([
            "--tag", "work", "--from", "2026-01-01T00:00:00Z", "--reveal", "--limit", "10",
        ])
        #expect(command.tag == ["work"])
        #expect(command.from == "2026-01-01T00:00:00Z")
        #expect(command.reveal)
        #expect(command.limit == 10)
    }

    @Test("profile journal remove parses UUID")
    func profileJournalRemoveParses() throws {
        let id = UUID()
        let command = try ProfileCommand.JournalCommand.RemoveCommand.parse([id.uuidString])
        #expect(command.id == id)
    }

    @Test("ProfileService adds and removes journal entries")
    func profileServiceJournalManagement() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let entry = try await service.addJournalEntry("Morning reflection", tags: ["morning"])
        #expect(entry.text == "Morning reflection")
        #expect(entry.tags == ["morning"])
        #expect(entry.accessScope == [.userInspection])

        var profile = try await service.load()
        #expect(profile.journalEntries.count == 1)

        try await service.removeJournalEntry(id: entry.id)
        profile = try await service.load()
        #expect(profile.journalEntries.isEmpty)
    }

    @Test("ProfileService journal entries filter by tags and dates")
    func profileServiceJournalFiltering() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let morning = try await service.addJournalEntry(
            "Morning",
            createdAt: ISO8601DateFormatter().date(from: "2026-07-01T08:00:00Z")!,
            tags: ["work"]
        )
        let evening = try await service.addJournalEntry(
            "Evening",
            createdAt: ISO8601DateFormatter().date(from: "2026-07-09T20:00:00Z")!,
            tags: ["work", "stress"]
        )

        let bothTags = try await service.journalEntries(tags: ["work", "stress"])
        #expect(bothTags.map(\.id) == [evening.id])

        let fromDate = ISO8601DateFormatter().date(from: "2026-07-05T00:00:00Z")!
        let recent = try await service.journalEntries(from: fromDate)
        #expect(recent.map(\.id) == [evening.id])

        let all = try await service.journalEntries()
        #expect(all.map(\.id) == [morning.id, evening.id])
    }

    @Test("UserProfile migrates legacy journalExcerpts to journalEntries")
    func legacyJournalExcerptsMigration() throws {
        let legacyJSON = """
        {
            "values": [],
            "goals": [],
            "boundaries": [],
            "financialHistory": { "items": [] },
            "journalExcerpts": { "items": ["old entry one", "old entry two"] }
        }
        """
        let data = Data(legacyJSON.utf8)
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        #expect(profile.journalEntries.count == 2)
        #expect(profile.journalEntries.map(\.text) == ["old entry one", "old entry two"])
        #expect(profile.journalEntries.allSatisfy { $0.accessScope == [.userInspection] })
    }

    @Test("UserProfile decodes new journalEntries directly")
    func newJournalEntriesDecoding() throws {
        let newJSON = """
        {
            "values": [],
            "goals": [],
            "boundaries": [],
            "financialHistory": { "items": [] },
            "journalEntries": [
                {
                    "id": "A0B1C2D3-E4F5-6789-0123-456789ABCDEF",
                    "text": "new entry",
                    "createdAt": 795088800,
                    "tags": ["travel"],
                    "accessScope": ["userInspection"],
                    "isLocked": false
                }
            ]
        }
        """
        let data = Data(newJSON.utf8)
        let profile = try JSONDecoder().decode(UserProfile.self, from: data)
        #expect(profile.journalEntries.count == 1)
        #expect(profile.journalEntries.first?.text == "new entry")
        #expect(profile.journalEntries.first?.tags == ["travel"])
    }

    @Test("UserProfile decodes pre-Phase-2 values/goals/boundaries without tags")
    func legacyProfileEntriesDecodeWithoutTags() throws {
        // Pre-Phase-2 entries omit `tags` (and createdAt/status/severity). A non-empty
        // legacy array must still decode instead of aborting the entire profile load.
        let legacyJSON = """
        {
            "values": [
                { "id": "A0B1C2D3-E4F5-6789-0123-456789ABCDEF", "text": "Be frugal" }
            ],
            "goals": [
                { "id": "A0B1C2D3-E4F5-6789-0123-456789ABCDE0", "text": "Save for travel", "timeframe": "2027" }
            ],
            "boundaries": [
                { "id": "A0B1C2D3-E4F5-6789-0123-456789ABCDE1", "text": "No impulse buys" }
            ],
            "financialHistory": { "items": [] }
        }
        """
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(legacyJSON.utf8))
        #expect(profile.values.count == 1)
        #expect(profile.values.first?.text == "Be frugal")
        #expect(profile.values.first?.tags == [])
        #expect(profile.goals.count == 1)
        #expect(profile.goals.first?.timeframe == "2027")
        #expect(profile.goals.first?.status == nil)
        #expect(profile.goals.first?.tags == [])
        #expect(profile.boundaries.count == 1)
        #expect(profile.boundaries.first?.severity == nil)
        #expect(profile.boundaries.first?.tags == [])
    }

    @Test("journal add rejects invalid ISO date")
    func journalAddRejectsInvalidDate() throws {
        #expect(throws: (any Error).self) {
            try parseISODate("not-a-date")
        }
        let valid = try parseISODate("2026-07-09T12:00:00Z")
        #expect(valid.timeIntervalSince1970 == 1783598400)
    }

    @Test("journal list redacts text unless reveal is set")
    func journalListRedaction() throws {
        let secret = "SECRET_DIARY_TEXT_DO_NOT_LEAK"
        let entry = JournalEntry(
            id: UUID(uuidString: "A0B1C2D3-E4F5-6789-0123-456789ABCDEF")!,
            text: secret,
            createdAt: ISO8601DateFormatter().date(from: "2026-07-09T20:00:00Z")!,
            tags: ["evening"]
        )

        // Text mode: redacted by default, revealed with --reveal.
        let redactedText = formatJournalListText(entries: [entry], reveal: false)
        #expect(redactedText.contains("(text redacted)"))
        #expect(!redactedText.contains(secret))

        let revealedText = formatJournalListText(entries: [entry], reveal: true)
        #expect(revealedText.contains(secret))

        // JSON mode: text is nil (omitted) by default, present with --reveal.
        let redactedItems = presentJournalListItems(entries: [entry], reveal: false)
        #expect(redactedItems.count == 1)
        #expect(redactedItems.first?.text == nil)

        let revealedItems = presentJournalListItems(entries: [entry], reveal: true)
        #expect(revealedItems.first?.text == secret)

        // Confirm the JSON wire format withholds the key entirely when redacted.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let redactedJSON = String(data: try encoder.encode(redactedItems), encoding: .utf8) ?? ""
        #expect(!redactedJSON.contains(secret))
    }

    @Test("MemoryService searches episodes")
    func memoryServiceSearchEpisodes() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        try await service.recordEpisode(
            sessionID: UUID(),
            question: "Should I buy a bike?",
            perspective: Perspective(summary: "No.")
        )
        try await service.recordEpisode(
            sessionID: UUID(),
            question: "Should I buy a car?",
            perspective: Perspective(summary: "Maybe.")
        )

        let bikeResults = try await service.searchEpisodes(query: "bike", limit: 10)
        #expect(bikeResults.count == 1)
        #expect(bikeResults.first?.question.contains("bike") == true)
    }

    @Test("MemoryService manages facts")
    func memoryServiceFactManagement() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        let fact = try await service.addFact(
            subject: "user",
            predicate: "budget",
            object: "500"
        )
        #expect(fact.subject == "user")

        let facts = try await service.facts(subject: "user")
        #expect(facts.count == 1)
        #expect(facts.first?.object == "500")
    }

    @Test("ModelManifestService lists and unregisters manifests")
    func modelManifestServiceListAndUnregister() async {
        let service = ModelManifestService()
        await service.register(ModelManifest(id: "a", checksum: "sha256:1"))
        await service.register(ModelManifest(id: "b", checksum: "sha256:2"))

        let manifests = await service.allManifests()
        #expect(manifests.count == 2)

        await service.unregister(id: "a")
        let remaining = await service.allManifests()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == "b")
    }

    @Test("MemoryService purpose-filtered facts enforce denial and audit the decision")
    func memoryServiceFactsByPurpose() async throws {
        let store = MockMemoryStore()
        let auditLog = MockAuditLog()
        let service = MemoryService(store: store, auditLog: auditLog)

        try await service.addFact(
            subject: "user",
            predicate: "ssn",
            object: "secret",
            accessScope: [.purchaseDeliberation, .travelDeliberation],
            deniedPurposes: [.purchaseDeliberation]
        )

        let purchase = try await service.facts(subject: "user", purposes: [.purchaseDeliberation])
        #expect(purchase.isEmpty)

        let travel = try await service.facts(subject: "user", purposes: [.travelDeliberation])
        #expect(travel.count == 1)

        // Each purpose-filtered read records an aggregate allow entry plus one
        // per-item entry for every denied fact.
        let allAudit = await auditLog.entries
        let accessEntries = allAudit.filter { $0.category == .memoryAccess }
        #expect(accessEntries.count == 3)
        #expect(accessEntries.allSatisfy { $0.payload["dataElementType"] == "TemporalFact" })
        let allowedEntries = accessEntries.filter { $0.payload["decision"] == "allowed" }
        let deniedEntries = accessEntries.filter { $0.payload["decision"] == "denied" }
        #expect(allowedEntries.count == 2)
        #expect(deniedEntries.count == 1)
        #expect(deniedEntries.first?.payload["purpose"] == "purchaseDeliberation")
        #expect(deniedEntries.first?.payload["elementID"] != nil)
    }

    @Test("ProfileService routableContext excludes journal entries")
    func profileServiceRoutableContext() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        try await service.addValue("Be frugal")
        try await service.addJournalEntry("private thought", tags: ["diary"])

        let context = try await service.routableContext(purposes: [.purchaseDeliberation])
        #expect(context.values.count == 1)
        #expect(context.values.first?.text == "Be frugal")
        // RoutableProfileContext has no journal field by construction; the profile still holds it.
        let profile = try await service.load()
        #expect(profile.journalEntries.count == 1)
    }

    @Test("ProfileService routableContext narrows items by purpose")
    func profileServiceRoutableContextNarrowsByPurpose() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        try await service.addValue("Be frugal")
        try await service.addValue("Travel light", accessScope: [.travelDeliberation])
        try await service.addGoal("Save for trips", deniedPurposes: [.purchaseDeliberation])
        try await service.addBoundary("No impulse buys")

        let purchase = try await service.routableContext(purposes: [.purchaseDeliberation])
        // Only the default-scoped value and boundary survive; the travel-scoped value is
        // out of scope and the goal is explicitly denied.
        #expect(purchase.values.map(\.text) == ["Be frugal"])
        #expect(purchase.goals.isEmpty)
        #expect(purchase.boundaries.map(\.text) == ["No impulse buys"])

        let travel = try await service.routableContext(purposes: [.travelDeliberation])
        #expect(travel.values.count == 2)
        #expect(travel.goals.count == 1)
        #expect(travel.boundaries.count == 1)
    }

    @Test("ProfileService profileAccessDecision reports per-item denials")
    func profileAccessDecisionReportsDenials() async throws {
        let vault = MockProfileVault()
        let service = ProfileService(vault: vault)
        let denied = try await service.addBoundary(
            "No work talk",
            deniedPurposes: [.lifeDeliberation]
        )
        try await service.addValue("Be curious")

        let decision = try await service.profileAccessDecision(purposes: [.lifeDeliberation])
        #expect(decision.context.values.count == 1)
        #expect(decision.context.boundaries.isEmpty)
        #expect(decision.denials.count == 1)
        #expect(decision.denials.first?.elementType == "Boundary")
        #expect(decision.denials.first?.elementID == denied.id)
        #expect(decision.denials.first?.purposes == [.lifeDeliberation])
    }

    @Test("Profile add commands parse purpose options")
    func parsesProfilePurposeOptions() throws {
        let value = try ProfileCommand.ValueCommand.AddCommand.parse([
            "Be frugal",
            "--tag", "money",
            "--purpose", "purchaseDeliberation",
            "--purpose", "lifeDeliberation",
            "--denied-purpose", "travelDeliberation",
        ])
        #expect(value.purpose == [.purchaseDeliberation, .lifeDeliberation])
        #expect(value.deniedPurpose == [.travelDeliberation])

        let goal = try ProfileCommand.GoalCommand.AddCommand.parse([
            "Save for travel",
            "--denied-purpose", "purchaseDeliberation",
        ])
        #expect(goal.purpose.isEmpty)
        #expect(goal.deniedPurpose == [.purchaseDeliberation])

        let boundary = try ProfileCommand.BoundaryCommand.AddCommand.parse([
            "No impulse buys",
            "--purpose", "purchaseDeliberation",
        ])
        #expect(boundary.purpose == [.purchaseDeliberation])
        #expect(boundary.deniedPurpose.isEmpty)
    }

    @Test("tools list command parses server and grant options")
    func parsesToolsList() throws {
        let command = try ToolsCommand.ListCommand.parse([
            "--server", "python3 server.py",
            "--purpose", "purchaseDeliberation",
            "--tool", "echo",
            "--tool", "add",
        ])
        #expect(command.server == "python3 server.py")
        #expect(command.purpose == [.purchaseDeliberation])
        #expect(command.tool == ["echo", "add"])
        #expect(command.options.format == .text)
    }

    @Test("tools call command parses arguments")
    func parsesToolsCall() throws {
        let command = try ToolsCommand.CallCommand.parse([
            "echo",
            "--server", "python3 server.py",
            "--args", #"{"text": "hi"}"#,
            "--format", "json",
        ])
        #expect(command.name == "echo")
        #expect(command.args == #"{"text": "hi"}"#)
        #expect(command.options.format == .json)
        #expect(command.purpose.isEmpty)
    }

    @Test("bare question routes to the ask default subcommand")
    func bareQuestionRoutesToAskDefaultSubcommand() throws {
        // Pins `defaultSubcommand: AskCommand`: a bare argument list must keep
        // routing to ask rather than failing or hitting another subcommand.
        let parsed = try CouncilCLI.parseAsRoot(["Should I buy?"])
        let ask = try #require(parsed as? AskCommand)
        #expect(ask.question == "Should I buy?")
    }

    @Test("UUID arguments reject malformed values and accept lowercase canonical")
    func uuidArgumentsRejectMalformed() throws {
        #expect(throws: (any Error).self) {
            try ProfileCommand.ValueCommand.RemoveCommand.parse(["not-a-uuid"])
        }
        #expect(throws: (any Error).self) {
            try MemoryCommand.ShowCommand.parse(["12345"])
        }
        #expect(throws: (any Error).self) {
            try ProfileCommand.JournalCommand.RemoveCommand.parse(["A0B1C2D3-E4F5-6789"])
        }

        let lowercase = "a0b1c2d3-e4f5-6789-0123-456789abcdef"
        let parsed = try ProfileCommand.ValueCommand.RemoveCommand.parse([lowercase])
        #expect(parsed.id.uuidString == "A0B1C2D3-E4F5-6789-0123-456789ABCDEF")
    }

    @Test("unknown output format is rejected on every subcommand shape")
    func formatOptionRejectsUnknownValue() {
        #expect(throws: (any Error).self) {
            try MemoryCommand.ListCommand.parse(["--format", "yaml"])
        }
        #expect(throws: (any Error).self) {
            try ProfileCommand.JournalCommand.ListCommand.parse(["--format", "yaml"])
        }
        #expect(throws: (any Error).self) {
            try AuditCommand.ListCommand.parse(["--format", "yaml"])
        }
    }
}
