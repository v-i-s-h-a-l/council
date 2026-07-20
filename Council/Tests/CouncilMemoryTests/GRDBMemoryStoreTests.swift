import CouncilCore
@testable import CouncilMemory
import CryptoKit
import Foundation
import GRDB
import Testing

struct GRDBMemoryStoreTests {
    private func makeStore() throws -> GRDBMemoryStore {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let salt = Data(repeating: 0xBB, count: 16)
        let dbQueue = try DatabaseQueue()
        return try GRDBMemoryStore(dbQueue: dbQueue, profileKey: rawKey, salt: salt)
    }

    @Test func saveAndLoadEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Should I buy a laptop?",
            perspective: Perspective(
                summary: "It is expensive but useful.",
                tradeOffs: ["cost", "productivity"],
                blindSpots: ["depreciation"],
                dissent: ["wait for sale"]
            )
        )

        try await store.saveEpisode(episode)
        let loaded = try await store.episodes(matching: MemoryFilter())

        #expect(loaded.count == 1)
        #expect(loaded.first?.question == episode.question)
        #expect(loaded.first?.perspective.summary == episode.perspective.summary)
        #expect(loaded.first?.perspective.tradeOffs == episode.perspective.tradeOffs)
    }

    @Test func updateEpisode() async throws {
        let store = try makeStore()
        var episode = EpisodicGist(
            sessionID: UUID(),
            question: "Original question?"
        )
        try await store.saveEpisode(episode)

        episode.question = "Updated question?"
        try await store.updateEpisode(episode)

        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.first?.question == "Updated question?")
    }

    @Test func deleteEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(sessionID: UUID(), question: "Delete me?")
        try await store.saveEpisode(episode)
        try await store.deleteEpisode(id: episode.id)

        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.isEmpty)
    }

    @Test func lockEpisode() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(sessionID: UUID(), question: "Lock me?")
        try await store.saveEpisode(episode)
        try await store.lockEpisode(id: episode.id, isLocked: true)

        let locked = try await store.episodes(matching: MemoryFilter(locked: true))
        let unlocked = try await store.episodes(matching: MemoryFilter(locked: false))
        #expect(locked.count == 1)
        #expect(unlocked.isEmpty)
    }

    @Test func saveAndLoadFact() async throws {
        let store = try makeStore()
        let fact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "MacBook Pro",
            accessScope: [.purchaseDeliberation]
        )

        try await store.saveFact(fact)
        let loaded = try await store.temporalFacts(matching: MemoryFilter())

        #expect(loaded.count == 1)
        #expect(loaded.first?.object == "MacBook Pro")
        #expect(loaded.first?.accessScope == [.purchaseDeliberation])
    }

    @Test func temporalFactsFilteredByPurpose() async throws {
        let store = try makeStore()
        let purchaseFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        )
        let travelFact = TemporalFact(
            subject: "user",
            predicate: "plans",
            object: "Japan trip",
            accessScope: [.travelDeliberation]
        )
        try await store.saveFact(purchaseFact)
        try await store.saveFact(travelFact)

        let purchaseFacts = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(purchaseFacts.count == 1)
        #expect(purchaseFacts.first?.object == "Laptop")

        let travelFacts = try await store.temporalFacts(for: .travelDeliberation)
        #expect(travelFacts.count == 1)
        #expect(travelFacts.first?.object == "Japan trip")
    }

    @Test func temporalFactsDeniedByPurpose() async throws {
        let store = try makeStore()
        let sensitive = TemporalFact(
            subject: "user",
            predicate: "ssn",
            object: "123-45-6789",
            accessScope: [.purchaseDeliberation, .travelDeliberation],
            deniedPurposes: [.purchaseDeliberation]
        )
        try await store.saveFact(sensitive)

        // Denied for purchase even though purchase is in accessScope.
        let purchase = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(purchase.isEmpty)

        let purchaseViaFilter = try await store.temporalFacts(
            matching: MemoryFilter(purposes: [.purchaseDeliberation])
        )
        #expect(purchaseViaFilter.isEmpty)

        // Still allowed for travel (in scope, not denied), and deniedPurposes round-trips.
        let travel = try await store.temporalFacts(for: .travelDeliberation)
        #expect(travel.count == 1)
        #expect(travel.first?.deniedPurposes == [.purchaseDeliberation])
    }

    @Test func lockedFactsExcludedFromAgentContext() async throws {
        let store = try makeStore()
        let unlockedFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Unlocked",
            accessScope: [.purchaseDeliberation]
        )
        var lockedFact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Locked",
            accessScope: [.purchaseDeliberation]
        )
        lockedFact.isLocked = true
        try await store.saveFact(unlockedFact)
        try await store.saveFact(lockedFact)

        let facts = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(facts.count == 1)
        #expect(facts.first?.object == "Unlocked")
    }

    @Test func sensitiveColumnsAreEncrypted() async throws {
        let store = try makeStore()
        let fact = TemporalFact(
            subject: "user",
            predicate: "balance",
            object: "12345.67",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(fact)

        // Read raw record and verify the object is not stored as plaintext UTF-8 bytes.
        let records = try await store.dbQueue.read { db in
            try TemporalFactRecord.fetchAll(db)
        }
        let rawObject = records.first?.objectEncrypted ?? Data()
        // The plaintext byte sequence must not appear anywhere inside the blob...
        #expect(rawObject.range(of: Data("12345.67".utf8)) == nil)
        // ...and the blob must carry the 12-byte nonce + 16-byte GCM tag overhead.
        #expect(rawObject.count >= 28)
    }

    @Test func episodeDeniedPurposesRoundTrip() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Should I day-trade?",
            deniedPurposes: [.lifeDeliberation]
        )
        try await store.saveEpisode(episode)

        // No purpose filter: the gist is returned with its deny set intact.
        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.count == 1)
        #expect(loaded.first?.deniedPurposes == [.lifeDeliberation])
    }

    @Test func episodesDeniedByPurpose() async throws {
        let store = try makeStore()
        let denied = EpisodicGist(
            sessionID: UUID(),
            question: "Sensitive purchase?",
            deniedPurposes: [.purchaseDeliberation]
        )
        let neutral = EpisodicGist(sessionID: UUID(), question: "Neutral purchase?")
        try await store.saveEpisode(denied)
        try await store.saveEpisode(neutral)

        let purchase = try await store.episodes(
            matching: MemoryFilter(purposes: [.purchaseDeliberation])
        )
        #expect(purchase.count == 1)
        #expect(purchase.first?.question == "Neutral purchase?")

        let travel = try await store.episodes(
            matching: MemoryFilter(purposes: [.travelDeliberation])
        )
        #expect(travel.count == 2)
    }

    @Test func migrationV3AddsEpisodeDeniedPurposesColumn() async throws {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let salt = Data(repeating: 0xBB, count: 16)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Legacy install: plaintext file database migrated only up to v2.
        let dbQueue = try DatabaseQueue(path: dbPath)
        try DatabaseMigrator.migrator().migrate(dbQueue, upTo: "v2")
        let columnsBefore = try await dbQueue.read { db in
            try db.columns(in: EpisodicGistRecord.databaseTableName).map(\.name)
        }
        #expect(!columnsBefore.contains("deniedPurposesJSON"))

        // Insert a v2-era episode row (no deniedPurposesJSON column) so the migration
        // must backfill the default for existing data.
        let databaseKey = GRDBMemoryStore.deriveDatabaseKey(from: rawKey, salt: salt)
        let summaryBlob = try FieldEncryption.encrypt(plaintext: Data("legacy".utf8), key: databaseKey)
        let emptyListBlob = try FieldEncryption.encrypt(plaintext: Data("[]".utf8), key: databaseKey)
        let legacyEpisodeID = UUID()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO episodic_gists
                (id, sessionID, question, createdAt, isLocked,
                 summaryEncrypted, tradeOffsEncrypted, blindSpotsEncrypted, dissentEncrypted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    legacyEpisodeID, UUID(), "Legacy question?", Date(timeIntervalSince1970: 1_700_000_000), false,
                    summaryBlob, emptyListBlob, emptyListBlob, emptyListBlob,
                ]
            )
        }

        // Opening the store applies v3.
        let store = try GRDBMemoryStore(
            dbQueue: dbQueue,
            profileKey: rawKey,
            salt: salt,
            useSQLCipher: false
        )
        let columnsAfter = try await dbQueue.read { db in
            try db.columns(in: EpisodicGistRecord.databaseTableName).map(\.name)
        }
        #expect(columnsAfter.contains("deniedPurposesJSON"))

        // The pre-v3 row reads back with an empty deny set.
        let legacy = try await store.episodes(matching: MemoryFilter())
        #expect(legacy.count == 1)
        #expect(legacy.first?.perspective.summary == "legacy")
        #expect(legacy.first?.deniedPurposes == [])

        // The store is fully functional on the migrated schema.
        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Post-migration?",
            deniedPurposes: [.travelDeliberation]
        )
        try await store.saveEpisode(episode)
        let loaded = try await store.episodes(matching: MemoryFilter())
        #expect(loaded.first { $0.id == episode.id }?.deniedPurposes == [.travelDeliberation])
    }

    @Test func corruptDeniedPurposesPayloadFailsClosed() async throws {
        let store = try makeStore()
        let episode = EpisodicGist(
            sessionID: UUID(),
            question: "Corrupt me?",
            deniedPurposes: [.purchaseDeliberation]
        )
        try await store.saveEpisode(episode)

        // Simulate store corruption: the deny-set JSON no longer parses.
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE episodic_gists SET deniedPurposesJSON = 'not-json' WHERE id = ?",
                arguments: [episode.id]
            )
        }

        // The episode decodes as denied for every purpose rather than routable.
        let all = try await store.episodes(matching: MemoryFilter())
        #expect(all.first?.deniedPurposes == AccessPurpose.allCases)
        for purpose in AccessPurpose.allCases {
            let filtered = try await store.episodes(matching: MemoryFilter(purposes: [purpose]))
            #expect(filtered.isEmpty)
        }
    }

    @Test func differentSaltsProduceDifferentDatabaseKeys() async throws {
        // Replaces the vacuous ciphertext comparison (a random per-message nonce
        // makes ciphertexts differ even for the SAME salt). What actually matters:
        // the salt drives key derivation, so different salts yield different keys
        // and data encrypted under one cannot be opened under the other.
        let rawKey = Data(repeating: 0xAB, count: 32)
        let key1 = GRDBMemoryStore.deriveDatabaseKey(from: rawKey, salt: Data(repeating: 0x01, count: 16))
        let key2 = GRDBMemoryStore.deriveDatabaseKey(from: rawKey, salt: Data(repeating: 0x02, count: 16))
        let key1Again = GRDBMemoryStore.deriveDatabaseKey(from: rawKey, salt: Data(repeating: 0x01, count: 16))

        #expect(key1 != key2)
        #expect(key1 == key1Again)

        let blob = try FieldEncryption.encrypt(plaintext: Data("secret".utf8), key: key1)
        #expect(throws: (any Error).self) {
            _ = try FieldEncryption.decrypt(ciphertext: blob, key: key2)
        }
    }

    // MARK: - Adversarial: purpose-bound access control

    @Test func expiredTemporalFactIsNotRoutedToAgentContext() async throws {
        let store = try makeStore()
        let now = Date()
        let expired = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Expired",
            validUntil: now.addingTimeInterval(-60),
            accessScope: [.purchaseDeliberation]
        )
        let notYetValid = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Future",
            validFrom: now.addingTimeInterval(3_600),
            accessScope: [.purchaseDeliberation]
        )
        let current = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Current",
            validFrom: now.addingTimeInterval(-3_600),
            validUntil: now.addingTimeInterval(3_600),
            accessScope: [.purchaseDeliberation]
        )
        let boundless = TemporalFact(
            subject: "user",
            predicate: "likes",
            object: "Boundless",
            accessScope: [.purchaseDeliberation]
        )
        for fact in [expired, notYetValid, current, boundless] {
            try await store.saveFact(fact)
        }

        // Regression: nothing used to evaluate validFrom/validUntil, so stale facts
        // flowed into agent prompts.
        let routed = try await store.temporalFacts(for: .purchaseDeliberation)
        let routedIDs = routed.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let expectedIDs = [current.id, boundless.id].sorted { $0.uuidString < $1.uuidString }
        #expect(routedIDs == expectedIDs)

        // Pin: the raw matching: query stays unfiltered — expiry only gates the
        // purpose-routed agent-context paths.
        let raw = try await store.temporalFacts(matching: MemoryFilter(purposes: [.purchaseDeliberation]))
        #expect(raw.count == 4)
    }

    @Test func emptyPurposesFilterDeniesAllFactsButNotEpisodes() async throws {
        let store = try makeStore()
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        ))
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: "Any question?"))

        // Fail closed: an empty request set is disjoint with every access scope,
        // so NO fact is authorized. "Empty" must not mean "unfiltered".
        let facts = try await store.temporalFacts(matching: MemoryFilter(purposes: []))
        #expect(facts.isEmpty)

        // Pin the deliberate asymmetry: episodes carry a deny set only (no scope),
        // so an empty request cannot overlap a deny set and the episode is returned.
        let episodes = try await store.episodes(matching: MemoryFilter(purposes: []))
        #expect(episodes.count == 1)
    }

    @Test func episodeSubjectFilterIsLocaleFuzzyButFactSubjectIsExact() async throws {
        let store = try makeStore()
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: "Buy a CAFÉ machine?"))
        try await store.saveFact(TemporalFact(
            subject: "Café",
            predicate: "located_in",
            object: "Lisbon",
            accessScope: [.travelDeliberation]
        ))

        // Pin the asymmetry: episode questions use localizedStandardContains
        // (case/diacritic-insensitive, locale-dependent)...
        let episodes = try await store.episodes(matching: MemoryFilter(subject: "café"))
        #expect(episodes.count == 1)

        // ...while fact subjects use an exact SQL equality.
        let fuzzyFacts = try await store.temporalFacts(matching: MemoryFilter(subject: "café"))
        #expect(fuzzyFacts.isEmpty)
        let exactFacts = try await store.temporalFacts(matching: MemoryFilter(subject: "Café"))
        #expect(exactFacts.count == 1)
    }

    // MARK: - Adversarial: corruption and fail-closed behavior

    @Test func corruptAccessScopeJSONFailsClosedPerRow() async throws {
        let store = try makeStore()
        let healthy = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        )
        let victim = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Fragile",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(healthy)
        try await store.saveFact(victim)

        // Simulate store corruption: the scope JSON of one row no longer parses.
        try await store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE temporal_facts SET accessScopeJSON = 'garbage' WHERE id = ?",
                arguments: [victim.id]
            )
        }

        // Regression: the corrupt row used to throw EVERY fetch (a one-row DoS).
        // It now decodes fail-closed per row, like a corrupt deny set.
        let all = try await store.temporalFacts(matching: MemoryFilter())
        #expect(all.count == 2)
        #expect(all.first { $0.id == victim.id }?.accessScope == [])

        // An empty scope authorizes nothing: the corrupt row is not routable.
        let routed = try await store.temporalFacts(for: .purchaseDeliberation)
        #expect(routed.map(\.id) == [healthy.id])
    }

    @Test func injectedSaltLengthEnforced() async throws {
        let rawKey = Data(repeating: 0xAA, count: 32)

        // Note: matched by type because GRDBMemoryStoreError has an associated-value
        // case and therefore is not Equatable.
        #expect(throws: GRDBMemoryStore.GRDBMemoryStoreError.self) {
            _ = try GRDBMemoryStore(
                dbQueue: DatabaseQueue(),
                profileKey: rawKey,
                salt: Data(repeating: 0x01, count: 15)
            )
        }
        #expect(throws: GRDBMemoryStore.GRDBMemoryStoreError.self) {
            _ = try GRDBMemoryStore(
                dbQueue: DatabaseQueue(),
                profileKey: rawKey,
                salt: Data(repeating: 0x01, count: 17)
            )
        }
        _ = try GRDBMemoryStore(
            dbQueue: DatabaseQueue(),
            profileKey: rawKey,
            salt: Data(repeating: 0x01, count: 16)
        )
    }

    @Test func truncatedSaltFileThrowsInsteadOfRekeying() async throws {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        // Ensure no stale keychain salt masks the corruption.
        let saltItem = KeychainItem(service: "com.council.memory.salt", account: dbPath)
        saltItem.delete()
        defer { saltItem.delete() }

        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: rawKey,
            useSQLCipher: false
        )
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        ))

        let saltURL = dir.appendingPathComponent("salt.bin")
        #expect(FileManager.default.fileExists(atPath: saltURL.path))

        // Corrupt the salt file (8 of 16 bytes survive) and remove the keychain
        // fallback so the corruption is unrecoverable. The store created salt.bin
        // with file protection, which an unsigned test runner may not overwrite
        // in place — delete first, then write the truncated bytes.
        try FileManager.default.removeItem(at: saltURL)
        try Data(repeating: 0xFF, count: 8).write(to: saltURL)
        saltItem.delete()

        // Regression: this used to silently generate a fresh salt, rekeying the
        // database and orphaning every stored row with no error.
        do {
            _ = try await GRDBMemoryStore.make(
                path: dbPath,
                profileKey: rawKey,
                useSQLCipher: false
            )
            Issue.record("Reopening with a corrupt salt file must throw, not silently rekey")
        } catch {
            guard case GRDBMemoryStore.GRDBMemoryStoreError.invalidSaltLength = error else {
                Issue.record("Expected invalidSaltLength, got \(error)")
                return
            }
        }

        // The originally opened store is unaffected and still reads its data.
        let facts = try await store.temporalFacts(matching: MemoryFilter())
        #expect(facts.count == 1)
    }

    @Test func wrongSaltInjectedOnReopenFailsLoudly() async throws {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: rawKey,
            salt: Data(repeating: 0x01, count: 16),
            useSQLCipher: false
        )
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "Laptop",
            accessScope: [.purchaseDeliberation]
        ))
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: "Q?"))

        // Reopening with a different salt derives a different key: reads must throw
        // a GCM authentication failure, never read as an empty database.
        let reopened = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: rawKey,
            salt: Data(repeating: 0x02, count: 16),
            useSQLCipher: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await reopened.temporalFacts(matching: MemoryFilter())
        }
        await #expect(throws: (any Error).self) {
            _ = try await reopened.episodes(matching: MemoryFilter())
        }
    }

    // MARK: - Adversarial: on-disk confidentiality

    @Test func sqlCipherFileContainsNoPlaintextOnDisk() async throws {
        let rawKey = Data(repeating: 0xAA, count: 32)
        let salt = Data(repeating: 0xBB, count: 16)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("memory.sqlite").path

        let store = try await GRDBMemoryStore.make(
            path: dbPath,
            profileKey: rawKey,
            salt: salt,
            useSQLCipher: true
        )
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "encrypted",
            object: "secret-data",
            accessScope: [.purchaseDeliberation]
        ))

        let secretBytes = Data("secret-data".utf8)
        let fileBytes = try Data(contentsOf: URL(fileURLWithPath: dbPath))

        // Full-database encryption: no SQLite header, and the plaintext appears
        // nowhere in the main file or the WAL.
        #expect(!fileBytes.starts(with: Data("SQLite format 3\0".utf8)))
        #expect(fileBytes.range(of: secretBytes) == nil)

        let walPath = dbPath + "-wal"
        if FileManager.default.fileExists(atPath: walPath) {
            let walBytes = try Data(contentsOf: URL(fileURLWithPath: walPath))
            #expect(walBytes.range(of: secretBytes) == nil)
        }
    }

    // MARK: - Adversarial: implicit semantics and hostile inputs

    @Test func duplicateIDSaveIsUpsertAndMissingIDOperationsAreSilent() async throws {
        let store = try makeStore()
        var fact = TemporalFact(
            subject: "user",
            predicate: "owns",
            object: "v1",
            accessScope: [.purchaseDeliberation]
        )
        try await store.saveFact(fact)
        fact.object = "v2"
        try await store.saveFact(fact)

        // Pin: saving twice with the same id upserts rather than duplicating.
        let facts = try await store.temporalFacts(matching: MemoryFilter())
        #expect(facts.count == 1)
        #expect(facts.first?.object == "v2")

        // Pin: delete/lock of absent ids affect zero rows without throwing.
        try await store.lockEpisode(id: UUID(), isLocked: true)
        try await store.deleteEpisode(id: UUID())
        try await store.deleteFact(id: UUID())

        let surviving = try await store.temporalFacts(matching: MemoryFilter())
        #expect(surviving.count == 1)
    }

    @Test func hugeAndHostileStringsRoundTrip() async throws {
        let store = try makeStore()

        let bigQuestion = String(repeating: "q", count: 10_000_000)
        let hostileSafe = "emoji 👨‍👩‍👧‍👦 rtl \u{202E}abc newline\nend"
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: bigQuestion))
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: hostileSafe))

        // Embedded NUL does not survive the TEXT column: retrieval is C-string
        // terminated. Pinned as documented behavior — questions are user text,
        // and binary-safe storage would need a BLOB column, not this fix.
        let withNul = "nul\u{0}byte"
        try await store.saveEpisode(EpisodicGist(sessionID: UUID(), question: withNul))

        let bigObject = String(repeating: "o", count: 1_000_000)
        try await store.saveFact(TemporalFact(
            subject: "user",
            predicate: "blob",
            object: bigObject,
            accessScope: [.purchaseDeliberation]
        ))

        let episodes = try await store.episodes(matching: MemoryFilter())
        #expect(episodes.count == 3)
        #expect(episodes.contains { $0.question == bigQuestion })
        #expect(episodes.contains { $0.question == hostileSafe })
        #expect(episodes.contains { $0.question == "nul" })

        let facts = try await store.temporalFacts(matching: MemoryFilter())
        #expect(facts.first?.object == bigObject)

        // A NUL byte in a subject filter is a bound parameter, not SQL: no crash,
        // no match.
        let nulFiltered = try await store.episodes(matching: MemoryFilter(subject: "\u{0}"))
        #expect(nulFiltered.isEmpty)
    }
}
