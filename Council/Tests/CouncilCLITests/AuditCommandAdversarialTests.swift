@testable import CouncilCLI
import Foundation
import Testing

/// Adversarial tests for `AuditCommand` limit handling.
@Suite("AuditCommand adversarial")
struct AuditCommandAdversarialTests {

    @Test("negative --limit is rejected instead of becoming an unbounded dump")
    func auditListNegativeLimitIsNotUnbounded() throws {
        // `--limit -1` reaches SQL as `LIMIT -1`, which SQLite treats as no
        // limit at all: the whole decrypted-metadata log would be dumped.
        // The CLI must reject it before it ever reaches the store.
        #expect(throws: (any Error).self) {
            try AuditCommand.ListCommand.parse(["--limit", "-1"])
        }
        #expect(throws: (any Error).self) {
            try AuditCommand.ListCommand.parse(["--limit", "-100"])
        }

        // Zero and positive limits stay valid and behave identically whether
        // or not payloads are included.
        let zero = try AuditCommand.ListCommand.parse(["--limit", "0"])
        #expect(zero.limit == 0)
        let five = try AuditCommand.ListCommand.parse(["--include-payloads", "--limit", "5"])
        #expect(five.limit == 5)
        #expect(five.includePayloads)
    }
}
