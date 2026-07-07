import Foundation
import GRDB

enum DatabaseMigrator {
    static let schemaVersion: Int32 = 1

    static func migrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()

        migrator.registerMigration("v1", migrate: { db in
            try db.create(table: EpisodicGistRecord.databaseTableName) { table in
                table.column("id", .blob).primaryKey()
                table.column("sessionID", .blob).notNull()
                table.column("question", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("isLocked", .boolean).notNull().defaults(to: false)
                table.column("summaryEncrypted", .blob).notNull()
                table.column("tradeOffsEncrypted", .blob).notNull()
                table.column("blindSpotsEncrypted", .blob).notNull()
                table.column("dissentEncrypted", .blob).notNull()
            }

            try db.create(table: TemporalFactRecord.databaseTableName) { table in
                table.column("id", .blob).primaryKey()
                table.column("subject", .text).notNull()
                table.column("predicate", .text).notNull()
                table.column("validFrom", .datetime)
                table.column("validUntil", .datetime)
                table.column("accessScopeJSON", .text).notNull()
                table.column("isLocked", .boolean).notNull().defaults(to: false)
                table.column("objectEncrypted", .blob).notNull()
            }

            try db.create(table: AuditLogRecord.databaseTableName) { table in
                table.column("id", .blob).primaryKey()
                table.column("sessionID", .blob)
                table.column("timestamp", .datetime).notNull()
                table.column("category", .text).notNull()
                table.column("previousHash", .text).notNull()
                table.column("hmac", .text).notNull()
                table.column("payloadEncrypted", .blob).notNull()
            }
        })

        return migrator
    }
}
