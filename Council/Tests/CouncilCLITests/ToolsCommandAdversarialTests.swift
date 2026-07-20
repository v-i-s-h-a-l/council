@testable import CouncilCLI
import Foundation
import Testing

/// Adversarial tests for the `server` label persisted in tool-call audit
/// entries. The label must identify the executable without ever persisting
/// secrets embedded in the command line.
@Suite("ToolsCommand adversarial")
struct ToolsCommandAdversarialTests {

    @Test("audit server label never persists env secrets")
    func toolsAuditLabelNeverPersistsEnvSecrets() {
        let secret = "supersecret123"

        // env wrapper with an inline secret assignment.
        let envLabel = auditServerLabel("env OPENAI_API_KEY=\(secret) python3 /tmp/fixture.py")
        #expect(envLabel == "python3")
        #expect(!envLabel.contains(secret))

        // Bare assignment prefix without an env wrapper.
        let bareLabel = auditServerLabel("OPENAI_API_KEY=\(secret) /usr/local/bin/server")
        #expect(bareLabel == "server")
        #expect(!bareLabel.contains(secret))

        // Multiple assignments before the executable.
        let multiLabel = auditServerLabel("FOO=\(secret) BAR=\(secret) /opt/tools/mcp server")
        #expect(multiLabel == "mcp")
        #expect(!multiLabel.contains(secret))
    }

    @Test("audit server label skips env's own flags")
    func toolsAuditLabelSkipsEnvFlags() {
        // `env -i KEY=v server`: the label must be the server, never "-i".
        #expect(auditServerLabel("env -i KEY=value server") == "server")
        #expect(auditServerLabel("env -i KEY=value /usr/bin/python3 x.py") == "python3")
        // Flag skipping applies only after a leading `env`.
        #expect(auditServerLabel("python3 fixture.py") == "python3")
    }

    @Test("audit server label degenerate inputs stay bounded")
    func toolsAuditLabelDegenerateInputs() {
        #expect(auditServerLabel("") == "unknown")
        #expect(auditServerLabel("env KEY=value") == "unknown")
        #expect(auditServerLabel("env") == "unknown")
        // Only the basename is kept, never the path.
        #expect(auditServerLabel("/very/long/path/to/server --flag") == "server")
    }
}
