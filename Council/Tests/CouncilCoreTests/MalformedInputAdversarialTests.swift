import Foundation
import Testing
@testable import CouncilCore

/// Adversarial coverage for decoding persisted state: unknown enum raw values,
/// missing/wrong-typed fields, truncated bytes, identity regeneration, default
/// scopes, and resource boundaries. One corrupt record currently fails the
/// entire store load — these tests pin that fail-closed blast radius as a
/// deliberate choice.
struct MalformedInputAdversarialTests {

    // MARK: - A10: unknown enum raw values fail closed (throw, not crash/default)

    @Test func unknownAccessPurposeRawValueFailsDecode() {
        let factJSON = """
        {"subject": "u", "predicate": "p", "object": "o", "accessScope": ["marketing"]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TemporalFact.self, from: Data(factJSON.utf8))
        }

        let valueJSON = """
        {"text": "v", "accessScope": ["marketing"]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ValueStatement.self, from: Data(valueJSON.utf8))
        }

        let deniedJSON = """
        {"text": "v", "deniedPurposes": ["advertising"]}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Goal.self, from: Data(deniedJSON.utf8))
        }
    }

    @Test func unknownGoalStatusAndBoundarySeverityRawValuesFailDecode() {
        let goalJSON = """
        {"text": "g", "status": "bogus"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Goal.self, from: Data(goalJSON.utf8))
        }

        let boundaryJSON = """
        {"text": "b", "severity": "bogus"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Boundary.self, from: Data(boundaryJSON.utf8))
        }
    }

    // MARK: - A11: missing or wrong-typed required fields throw

    @Test func missingRequiredTextThrowsForTolerantModels() {
        let emptyObject = "{}"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ValueStatement.self, from: Data(emptyObject.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Goal.self, from: Data(emptyObject.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Boundary.self, from: Data(emptyObject.utf8))
        }

        let wrongType = """
        {"text": 123}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ValueStatement.self, from: Data(wrongType.utf8))
        }
    }

    @Test func episodicGistDecoderIsStricterThanTolerantModels() {
        // Unlike ValueStatement/Goal/Boundary, EpisodicGist requires sessionID,
        // question, createdAt, AND perspective. Pin the asymmetry deliberately.
        let gistID = UUID().uuidString
        let sessionID = UUID().uuidString

        let missingSessionID = """
        {"id": "\(gistID)", "question": "q", "createdAt": 700000000, "perspective": {}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EpisodicGist.self, from: Data(missingSessionID.utf8))
        }

        let missingCreatedAt = """
        {"sessionID": "\(sessionID)", "question": "q", "perspective": {}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EpisodicGist.self, from: Data(missingCreatedAt.utf8))
        }

        let missingPerspective = """
        {"sessionID": "\(sessionID)", "question": "q", "createdAt": 700000000}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EpisodicGist.self, from: Data(missingPerspective.utf8))
        }

        // And a fully populated gist still decodes with PBAC defaults.
        let complete = """
        {"sessionID": "\(sessionID)", "question": "q", "createdAt": 700000000, "perspective": {"summary": "", "tradeOffs": [], "blindSpots": [], "dissent": []}}
        """
        let gist = try? JSONDecoder().decode(EpisodicGist.self, from: Data(complete.utf8))
        #expect(gist != nil)
        #expect(gist?.deniedPurposes.isEmpty == true)
        #expect(gist?.isLocked == false)
    }

    @Test func truncatedAndNonJSONBytesThrowDecodingErrorNotCrash() {
        let truncated = """
        {"text": "cut off mid-str
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ValueStatement.self, from: Data(truncated.utf8))
        }

        let notJSON = Data([0x00, 0xFF, 0xFE, 0x41, 0x00])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UserProfile.self, from: notJSON)
        }
    }

    // MARK: - A12: legacy decode mints fresh identities each time

    @Test func legacyDecodeWithoutIdGeneratesFreshUUIDEachTime() throws {
        // Persisted pre-PBAC items carry no id; re-decoding on every load mints
        // new identities, so dedup/migration keyed by id silently duplicates.
        // Pin the hazard so it is a documented behavior, not a surprise.
        let legacyJSON = """
        {"text": "Be frugal"}
        """
        let first = try JSONDecoder().decode(ValueStatement.self, from: Data(legacyJSON.utf8))
        let second = try JSONDecoder().decode(ValueStatement.self, from: Data(legacyJSON.utf8))
        #expect(first.id != second.id)
        #expect(first.text == second.text)
    }

    // MARK: - A15: asymmetric default scopes are privacy-relevant

    @Test func temporalFactAndJournalEntryDefaultScopesAreAsymmetric() {
        // A fact written without explicit scope is invisible to travel/life
        // deliberation; a journal entry defaults to user-inspection only.
        let fact = TemporalFact(subject: "u", predicate: "p", object: "o")
        #expect(fact.accessScope == [.purchaseDeliberation])

        let entry = JournalEntry(text: "private")
        #expect(entry.accessScope == [.userInspection])
        #expect(!entry.isLocked)

        // Contrast with the routable profile elements.
        #expect(ValueStatement(text: "v").accessScope == AccessPurpose.allDeliberation)
        #expect(Goal(text: "g").accessScope == AccessPurpose.allDeliberation)
        #expect(Boundary(text: "b").accessScope == AccessPurpose.allDeliberation)
    }

    // MARK: - A17: oversized fields round-trip without crash

    @Test func oversizedTextFieldsDecodeWithoutCrash() throws {
        let bigText = String(repeating: "x", count: 1_000_000)
        let manyTags = (0..<10_000).map { "tag-\($0)" }

        let value = ValueStatement(text: bigText, tags: manyTags)
        let valueData = try JSONEncoder().encode(value)
        let decodedValue = try JSONDecoder().decode(ValueStatement.self, from: valueData)
        #expect(decodedValue.text.count == 1_000_000)
        #expect(decodedValue.tags.count == 10_000)

        let entry = JournalEntry(text: bigText, tags: manyTags)
        let entryData = try JSONEncoder().encode(entry)
        let decodedEntry = try JSONDecoder().decode(JournalEntry.self, from: entryData)
        #expect(decodedEntry.text.count == 1_000_000)
        #expect(decodedEntry.tags.count == 10_000)
    }

    // MARK: - A18: no validation on inference options (pin absence deliberately)

    @Test func inferenceOptionsAcceptDegenerateValues() {
        // These flow verbatim to providers; when clamping is added it is a
        // deliberate breaking change and this test must be revisited.
        let degenerate = InferenceOptions(temperature: -.infinity, maxTokens: 0)
        #expect(degenerate.temperature == -.infinity)
        #expect(degenerate.maxTokens == 0)

        let huge = InferenceOptions(maxTokens: Int.max)
        #expect(huge.maxTokens == Int.max)

        let negativeRetries = RetryBudget(maxRetries: -1, baseDelayMilliseconds: 0)
        #expect(negativeRetries.maxRetries == -1)
    }

    // MARK: - A20: agent outputs cross the inference boundary

    @Test func agentOutputRoundTripsAndUnknownStanceFailsDecode() throws {
        let output = AgentOutput(
            agentID: "skeptic-1",
            opinion: "Do not buy it.",
            rationale: "Budget constraint.",
            stance: .skeptical
        )
        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(AgentOutput.self, from: data)
        #expect(decoded.agentID == "skeptic-1")
        #expect(decoded.opinion == "Do not buy it.")
        #expect(decoded.rationale == "Budget constraint.")
        #expect(decoded.stance == .skeptical)

        let unknownStance = """
        {"agentID": "a", "opinion": "o", "rationale": "r", "stance": "hostile"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentOutput.self, from: Data(unknownStance.utf8))
        }
    }
}
