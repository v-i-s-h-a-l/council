import CouncilCore
@testable import CouncilTools
import Foundation
import Testing

struct MCPToolConnectorTests {
    /// Mutable capture target for `@Sendable` decision callbacks in tests.
    private final class DecisionRecorder: @unchecked Sendable {
        private(set) var decisions: [ToolAccessDecision] = []
        func record(_ decision: ToolAccessDecision) { decisions.append(decision) }
    }

    // MARK: - Fixture server

    /// Writes a newline-delimited JSON-RPC fixture MCP server to a temp file and
    /// returns the shell command that runs it.
    private func makeFixtureServer() throws -> (command: String, cleanup: () -> Void) {
        let script = """
        import sys, json

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            method = msg.get("method")
            if method == "initialize":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "0.0.1"}}}
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [
                    {"name": "echo", "description": "Echo back the input", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
                    {"name": "add", "description": "Add two numbers", "inputSchema": {"type": "object"}}
                ]}}
            elif method == "tools/call":
                name = msg["params"]["name"]
                args = msg["params"].get("arguments", {})
                if name == "echo":
                    resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": args.get("text", "")}], "isError": False}}
                elif name == "add":
                    resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": str(args.get("a", 0) + args.get("b", 0))}], "isError": False}}
                else:
                    resp = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown tool"}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-tools-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fixture_server.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        return ("python3 \(path.path)", { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: - Round trip

    @Test func listAndCallFixtureServer() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        let tools = try await connector.listTools()
        #expect(tools.map(\.name) == ["echo", "add"])
        #expect(tools.first?.description == "Echo back the input")
        #expect(tools.first?.inputSchema?.contains("properties") == true)

        let echo = try await connector.callTool(name: "echo", argumentsJSON: #"{"text": "hello council"}"#)
        #expect(echo == "hello council")

        let sum = try await connector.callTool(name: "add", argumentsJSON: #"{"a": 2, "b": 40}"#)
        #expect(sum == "42")
    }

    @Test func callWithEmptyArgumentsDefaultsToEmptyObject() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        let echo = try await connector.callTool(name: "echo", argumentsJSON: "")
        #expect(echo == "")
    }

    @Test func unknownToolYieldsServerError() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.callTool(name: "missing", argumentsJSON: "{}")
            Issue.record("expected serverError")
        } catch ToolConnectorError.serverError(let message) {
            #expect(message == "unknown tool")
        }
    }

    @Test func nonObjectArgumentsRejected() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.callTool(name: "echo", argumentsJSON: "[1,2]")
            Issue.record("expected protocolError")
        } catch ToolConnectorError.protocolError {
        }
    }

    // MARK: - Failure modes

    @Test func malformedServerYieldsProtocolError() async throws {
        let connector = MCPToolConnector(command: "echo not-json", timeout: 5)
        defer { Task { await connector.terminate() } }
        do {
            _ = try await connector.listTools()
            Issue.record("expected protocolError")
        } catch ToolConnectorError.protocolError {
        }
    }

    @Test func hungServerTimesOut() async throws {
        let connector = MCPToolConnector(command: "sleep 30", timeout: 1)
        defer { Task { await connector.terminate() } }
        do {
            _ = try await connector.listTools()
            Issue.record("expected timeout")
        } catch ToolConnectorError.timeout {
        }
    }

    @Test func nonexistentCommandYieldsProtocolErrorOrSpawnFailure() async throws {
        let connector = MCPToolConnector(command: "/nonexistent/council-fixture-server", timeout: 5)
        defer { Task { await connector.terminate() } }
        do {
            _ = try await connector.listTools()
            Issue.record("expected an error")
        } catch ToolConnectorError.spawnFailed {
        } catch ToolConnectorError.protocolError {
            // /bin/sh spawns but the command fails, closing stdout.
        }
    }

    // MARK: - Grant enforcement

    @Test func grantDeniesUnlistedToolBeforeSpawning() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-tools-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // If the connector were spawned, this command would create the marker file.
        let connector = MCPToolConnector(command: "touch \(marker.path)", timeout: 5)
        let recorder = DecisionRecorder()
        let granted = GrantEnforcingConnector(
            connector: connector,
            grant: ToolGrant(purposes: [.purchaseDeliberation], allowedTools: ["echo"]),
            onDecision: { recorder.record($0) }
        )

        do {
            _ = try await granted.callTool(name: "exec", argumentsJSON: "{}")
            Issue.record("expected accessDenied")
        } catch ToolConnectorError.accessDenied {
        }

        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        #expect(recorder.decisions.count == 1)
        #expect(recorder.decisions.first?.allowed == false)
        #expect(recorder.decisions.first?.toolName == "exec")
    }

    @Test func grantWithEmptyPurposesDeniesEverything() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 5)
        let granted = GrantEnforcingConnector(
            connector: connector,
            grant: ToolGrant(purposes: [])
        )

        do {
            _ = try await granted.listTools()
            Issue.record("expected accessDenied")
        } catch ToolConnectorError.accessDenied {
        }
    }

    @Test func grantReportsAllowDecision() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }
        let recorder = DecisionRecorder()
        let granted = GrantEnforcingConnector(
            connector: connector,
            grant: ToolGrant(purposes: [.userInspection]),
            onDecision: { recorder.record($0) }
        )

        _ = try await granted.listTools()
        #expect(recorder.decisions.count == 1)
        #expect(recorder.decisions.first?.allowed == true)
        #expect(recorder.decisions.first?.operation == "listTools")
    }

    // MARK: - Robustness regressions

    @Test func concurrentCallsAreSerialized() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        // Regression: concurrent callers previously crashed the process via
        // simultaneous next() on the shared stream iterator (actor reentrancy).
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await connector.callTool(name: "echo", argumentsJSON: #"{"text": "msg-\#(index)"}"#)
                }
            }
            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            #expect(results.sorted() == (0..<8).map { "msg-\($0)" }.sorted())
        }
    }

    @Test func unterminatedMegalineFailsConnection() async throws {
        // Server emits one 2 MB line with no newline terminator.
        let flood = "python3 -c \"import sys; sys.stdout.write('x' * 2000000); sys.stdout.flush()\""
        let connector = MCPToolConnector(command: flood, timeout: 10)
        defer { Task { await connector.terminate() } }
        do {
            _ = try await connector.listTools()
            Issue.record("expected protocolError from byte cap")
        } catch ToolConnectorError.protocolError(let message) {
            #expect(message.contains("unterminated line"))
        }
    }
}
