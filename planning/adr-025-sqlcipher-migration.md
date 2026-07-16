# ADR-025: SQLCipher Full-Database Encryption for GRDB Stores

**Status:** Accepted  
**Lifecycle record:** `6171148c-c5fd-4d38-bd99-786de23866ac`  
**Issue:** #25  
**Date:** 2026-07-09  
**Implementation date:** 2026-07-15

## Context

Council's memory and audit stores use GRDB.swift with **column-level AES-256-GCM encryption** (`GRDBMemoryStore.swift`). Sensitive fields such as episode perspective summaries, fact objects, and audit payloads are encrypted before being written. However, SQLite metadata remains plaintext:

- Table and column names
- Row counts and primary keys
- Timestamps and foreign-key relationships
- Index contents and query patterns

For a local-first, privacy-sensitive system, this metadata leakage is a residual risk. SQLCipher provides **full-database encryption** at the page level, which closes this gap.

## Decision

Adopt SQLCipher as the SQLite backend for GRDB. Until Swift Package Manager supports package traits, GRDB must be forked to swap the SQLite backend for SQLCipher ([GRDB 7.10.0 Swift Forums announcement](https://forums.swift.org/t/grdb-v7-10-0-android-linux-windows-and-sqlcipher-swiftpm/84754)).

The fork is maintained at `GRDB.swift-sqlcipher/` (tag `v7.10.0-sqlcipher-council-1`) and referenced as a local path dependency in `Council/Package.swift`. The SQLCipher library is provided by `sqlcipher/SQLCipher.swift` (4.17.0 binary XCFramework).

## Consequences

### Benefits

- All SQLite pages are AES-256 encrypted, including schema, indexes, and metadata.
- The existing column-level encryption remains in place as defense-in-depth during and after the migration.
- The `GRDBMemoryStore` public API stays unchanged; consumers do not need to be modified.

### Risks

- A forked GRDB dependency adds supply-chain and maintenance burden.
- SQLCipher compile times are longer than system SQLite.
- A one-way migration must run correctly on first launch; a failed migration could leave the user without memory/audit data.

## Migration approach

### 1. Dependency changes

- Fork `groue/GRDB.swift` at a tag ≥ 7.10.0 and follow the `GRDB+SQLCipher` comments in `Package.swift`.
- Pin the fork to an exact tag in `Council/Package.swift`.
- Add the SQLCipher package dependency declared by the fork.
- Keep the existing GRDB 7.9.0 dependency only during a transitional branch; remove it once migration tests pass.

### 2. Keying

Council already derives a 32-byte database key from the profile key:

```swift
let derived = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: inputKey,
    salt: salt,
    info: Data("com.council.memory.database.v1".utf8),
    outputByteCount: 32
)
```

SQLCipher must be opened with this raw 32-byte key, **not** as a passphrase, to avoid an additional PBKDF2 round and to preserve the existing key hierarchy:

```sql
PRAGMA key = "x'<64-hex-characters>'";
```

The hex string is the lower-case representation of the 32-byte `databaseKey`.

### 3. Migration sequence

Implement `SQLCipherMigration` in `CouncilMemory`:

1. Check for a legacy database file (`memory.sqlite`) and a marker file (`memory.sqlite.sqlcipher`).
2. If the marker exists, open the SQLCipher database normally.
3. If the legacy database exists and no marker exists:
   a. Open the legacy database with the current GRDB + column-level decryption.
   b. Create a new SQLCipher database at `memory.sqlite.next`.
   c. Copy `EpisodicGistRecord`, `TemporalFactRecord`, and `AuditEntryRecord` rows, decrypting and re-encrypting sensitive columns with the existing derived key.
   d. Close both databases.
   e. Move `memory.sqlite` to `memory.sqlite.pre-sqlcipher-backup`.
   f. Move `memory.sqlite.next` to `memory.sqlite`.
   g. Write the marker file `memory.sqlite.sqlcipher`.
4. If neither file exists, create a fresh SQLCipher database.

### 4. Rollback

- Before migration, the legacy database is moved to `memory.sqlite.pre-sqlcipher-backup`.
- If migration fails at any step, delete the partial `memory.sqlite.next`, restore the backup, and throw a migration error.
- On the next launch, the app will retry the migration.
- After a successful launch, the backup may be retained for one additional launch as a safety net, then removed.

### 5. Validation

- Existing `GRDBMemoryStoreTests` must pass without modification.
- Add a new `SQLCipherMigrationTests` suite that:
  - Creates a legacy database with known episodes, facts, and audit entries.
  - Runs the migration.
  - Asserts the SQLCipher database contains the same decrypted data.
  - Asserts the legacy backup exists and the marker file is written.
- Run the AC16 benchmark to confirm no performance regression beyond acceptable bounds.

## Data-migration concerns

- **Salt preservation:** The 16-byte salt used to derive the database key must not change. `SQLCipherMigration` reuses the existing `salt.bin`.
- **Audit chain integrity:** Audit entries are cryptographically chained. The migration copies entries in chronological order and preserves `previousHash` and `hmac` values.
- **No data loss for in-memory databases:** Tests that use `:memory:` databases will use SQLCipher in-memory mode where supported; otherwise they will continue to use the current GRDB until the fork stabilizes.

## Implementation notes

### GRDB fork setup

The fork at `GRDB.swift-sqlcipher/` (tag `v7.10.0-sqlcipher-council-1`) follows the `GRDB+SQLCipher` comments in the stock `Package.swift`. One additional fix was required: the fork's `GRDBSQLCipher` target was renamed to `GRDBSQLite` (with a matching `module GRDBSQLite` modulemap) so that all 33 `import GRDBSQLite` statements in GRDB sources resolve to the SQLCipher backend without modification. The stale system-library `Sources/GRDBSQLite/` directory was removed.

SQLCipher is provided by the `sqlcipher/SQLCipher.swift` package (4.17.0), which ships a pre-built XCFramework — no source compilation required.

### Key application order

For file-based databases, `PRAGMA key` must be set via `Configuration.prepareDatabase` **before** GRDB runs its own initialization SQL (`PRAGMA journal_mode`, `SELECT * FROM sqlite_master`). The `GRDBMemoryStore.make(path:)` and `GRDBAuditLog.make(path:)` factory methods resolve the salt and derive the key before creating the `DatabaseQueue`, then pass a `sqlCipherConfiguration(key:)` to the queue initializer.

For in-memory databases (`:memory:`), `PRAGMA key` applied via `writeWithoutTransaction` works because there is no file header to conflict with. The `init(dbQueue:)` path uses this approach.

### Shared queue compatibility

When `GRDBMemoryStore` and `GRDBAuditLog` share a single in-memory `DatabaseQueue` (as in `ProfileMemoryIntegrationTests`), the second initializer detects existing tables via `hasExistingTables()` and skips re-applying `PRAGMA key`, preventing a key mismatch.

### API changes

- `GRDBMemoryStore.init` and `GRDBAuditLog.init` gain a `useSQLCipher: Bool = true` parameter and an optional `salt: Data?` parameter.
- `GRDBMemoryStore.make(path:)` and `GRDBAuditLog.make(path:)` gain the same parameters.
- `GRDBMemoryStore.resolveSalt(forPath:injectedSalt:)`, `deriveDatabaseKey(from:salt:)`, `applySQLCipherKey(dbQueue:key:)`, and `sqlCipherConfiguration(key:)` are internal (not private) for use by `GRDBAuditLog` and `SQLCipherMigration`.

### New files

- `Council/Sources/CouncilMemory/SQLCipherMigration.swift` — `SQLCipherMigration` enum with `detectLegacyDatabase(at:)`, `isMigrated(at:)`, `migrate(legacyPath:profileKey:salt:)`, and `rollback(at:)`.
- `Council/Tests/CouncilMemoryTests/SQLCipherMigrationTests.swift` — 12 tests covering detection, encryption, migration, rollback, and marker file validation.

## References

- GRDB 7.10.0 SQLCipher + SPM announcement: https://forums.swift.org/t/grdb-v7-10-0-android-linux-windows-and-sqlcipher-swiftpm/84754
- GRDB encryption documentation: https://github.com/groue/GRDB.swift/blob/master/README.md#encryption
- SQLCipher PRAGMA key raw mode: https://www.zetetic.net/sqlcipher/sqlcipher-api/#key
