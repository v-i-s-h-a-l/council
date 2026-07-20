import CouncilCore
@testable import CouncilTools
import Foundation
import Testing

struct MCPToolConnectorTests {
    /// Mutable capture target for `@Sendable` decision callbacks in tests.
    private final class DecisionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ToolAccessDecision] = []
        var decisions: [ToolAccessDecision] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func record(_ decision: ToolAccessDecision) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(decision)
        }
    }

    /// In-memory connector for grant tests that must prove no process spawns.
    private struct StubConnector: ToolConnector {
        var tools: [ToolDescriptor] = []
        func listTools() async throws -> [ToolDescriptor] { tools }
        func callTool(name: String, argumentsJSON: String) async throws -> String { "stub" }
    }

    // MARK: - Fixture servers

    /// Writes a python3 fixture script to a temp file and returns the shell
    /// command that runs it.
    private func makeCustomServer(_ script: String) throws -> (command: String, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-tools-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fixture_server.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        return ("python3 \(path.path)", { try? FileManager.default.removeItem(at: dir) })
    }

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
        return try makeCustomServer(script)
    }

    /// A fixture server that completes the MCP handshake, then answers
    /// `tools/list` and `tools/call` with the given result fragments, spliced
    /// verbatim into the script (use Python literals: `True`/`False`/`None`).
    private func makeCustomResponseServer(
        listResult: String,
        callResult: String
    ) throws -> (command: String, cleanup: () -> Void) {
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
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": \(listResult)}
            elif method == "tools/call":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": \(callResult)}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        return try makeCustomServer(script)
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

    @Test func emptyOrWhitespaceArgumentsSendEmptyObject() async throws {
        // Stronger oracle than the removed callWithEmptyArgumentsDefaultsToEmptyObject:
        // this fixture echoes the raw arguments JSON, proving "{}" was sent
        // (the old fixture returned "" for any arguments lacking "text").
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
            elif method == "tools/call":
                args = msg["params"].get("arguments", {})
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": json.dumps(args)}], "isError": False}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        #expect(try await connector.callTool(name: "echo", argumentsJSON: "") == "{}")
        #expect(try await connector.callTool(name: "echo", argumentsJSON: "   ") == "{}")
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

    /// Regression: malformed argumentsJSON (including top-level scalars, which
    /// JSONSerialization rejects without .allowFragments) previously leaked a
    /// raw Cocoa error instead of ToolConnectorError.protocolError.
    @Test(arguments: ["null", "123", "\"str\"", "{", "not json"])
    func malformedArgumentsJSONYieldsProtocolError(argumentsJSON: String) async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.callTool(name: "echo", argumentsJSON: argumentsJSON)
            Issue.record("expected protocolError for \(argumentsJSON)")
        } catch ToolConnectorError.protocolError(let message) {
            #expect(message.contains("JSON"))
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

    @Test func nonexistentCommandYieldsProtocolError() async throws {
        // /bin/sh itself always spawns on macOS, so the missing command exits
        // immediately, closing stdout: the failure always surfaces as
        // protocolError. (The spawnFailed branch of ensureStarted would only
        // run if /bin/sh were missing, so it has no coverage by construction.)
        let connector = MCPToolConnector(command: "/nonexistent/council-fixture-server", timeout: 5)
        defer { Task { await connector.terminate() } }
        do {
            _ = try await connector.listTools()
            Issue.record("expected protocolError")
        } catch ToolConnectorError.protocolError {
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
        // A denied operation never spawns a server by design, so an in-memory
        // stub proves the same thing with no python3 dependency.
        let granted = GrantEnforcingConnector(
            connector: StubConnector(),
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

    // MARK: - Adversarial: timeout validation

    /// Regression: withTimeout computed UInt64(seconds * 1e9), which traps on
    /// negative/NaN timeouts and takes down the whole process.
    @Test func negativeOrNaNTimeoutDoesNotTrap() async throws {
        let badTimeouts: [TimeInterval] = [-1, .nan]
        for badTimeout in badTimeouts {
            let connector = MCPToolConnector(command: "sleep 30", timeout: badTimeout)
            do {
                _ = try await connector.listTools()
                Issue.record("expected immediate timeout for timeout \(badTimeout)")
            } catch ToolConnectorError.timeout {
            }
            await connector.terminate()
        }
    }

    @Test func infiniteTimeoutClampsAndStillWorks() async throws {
        let fixture = try makeFixtureServer()
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: .infinity)
        defer { Task { await connector.terminate() } }

        let tools = try await connector.listTools()
        #expect(tools.map(\.name) == ["echo", "add"])
    }

    // MARK: - Adversarial: grant filtering and audit decisions

    @Test func grantFiltersToolDiscoveryToAllowlist() async throws {
        // Confidentiality: tool names/descriptions flow into model prompts, so
        // an allowlisted grant must not learn about tools it cannot invoke.
        let recorder = DecisionRecorder()
        let granted = GrantEnforcingConnector(
            connector: StubConnector(tools: [
                ToolDescriptor(name: "echo", description: "Echo back the input"),
                ToolDescriptor(name: "add", description: "Add two numbers"),
            ]),
            grant: ToolGrant(purposes: [.userInspection], allowedTools: ["echo"]),
            onDecision: { recorder.record($0) }
        )

        let tools = try await granted.listTools()
        #expect(tools.map(\.name) == ["echo"])
        #expect(recorder.decisions.count == 1)
        #expect(recorder.decisions.first?.allowed == true)
    }

    @Test func nilAllowlistPermitsUnlistedTool() async throws {
        // `allowedTools: nil` means "all tools" — pin the default so it is not
        // later "fixed" into meaning none.
        let recorder = DecisionRecorder()
        let granted = GrantEnforcingConnector(
            connector: StubConnector(),
            grant: ToolGrant(purposes: [.userInspection], allowedTools: nil),
            onDecision: { recorder.record($0) }
        )

        let result = try await granted.callTool(name: "anything", argumentsJSON: "{}")
        #expect(result == "stub")
        #expect(recorder.decisions.count == 1)
        #expect(recorder.decisions.first?.allowed == true)
    }

    @Test func allowlistDenialRecordsPurposesAndReason() async throws {
        // The audit entry is built from decision.purposes; a dropped or emptied
        // copy would silently weaken every audit record.
        let recorder = DecisionRecorder()
        let granted = GrantEnforcingConnector(
            connector: StubConnector(),
            grant: ToolGrant(purposes: [.purchaseDeliberation, .userInspection], allowedTools: ["echo"]),
            onDecision: { recorder.record($0) }
        )

        do {
            _ = try await granted.callTool(name: "exec", argumentsJSON: "{}")
            Issue.record("expected accessDenied")
        } catch ToolConnectorError.accessDenied(let reason) {
            #expect(reason.contains("exec"))
        }

        #expect(recorder.decisions.count == 1)
        #expect(recorder.decisions.first?.allowed == false)
        #expect(recorder.decisions.first?.operation == "callTool")
        #expect(recorder.decisions.first?.toolName == "exec")
        #expect(recorder.decisions.first?.purposes == [.purchaseDeliberation, .userInspection])
    }

    // MARK: - Adversarial: response shape fidelity

    @Test func toolLevelIsErrorThrowsServerError() async throws {
        // The JSON-RPC error path is tested elsewhere; this is the MCP-level
        // `isError: true` result path, which carries the failure text.
        let fixture = try makeCustomResponseServer(
            listResult: #"{"tools": []}"#,
            callResult: #"{"content": [{"type": "text", "text": "boom"}], "isError": True}"#
        )
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.callTool(name: "echo", argumentsJSON: "{}")
            Issue.record("expected serverError")
        } catch ToolConnectorError.serverError(let message) {
            #expect(message == "boom")
        }
    }

    @Test func toolLevelIsErrorWithoutContentYieldsEmptyReason() async throws {
        // Pin the degenerate case: isError with no content currently throws
        // serverError("") — an empty reason that lands in the audit chain.
        let fixture = try makeCustomResponseServer(
            listResult: #"{"tools": []}"#,
            callResult: #"{"isError": True}"#
        )
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.callTool(name: "echo", argumentsJSON: "{}")
            Issue.record("expected serverError")
        } catch ToolConnectorError.serverError(let message) {
            #expect(message == "")
        }
    }

    @Test func nonTextContentPartsAreDroppedAndTextPartsJoined() async throws {
        // Pin two deliberate behaviors: multiple text parts join with "\n",
        // and non-text parts (e.g. images) are dropped rather than surfaced.
        let fixture = try makeCustomResponseServer(
            listResult: #"{"tools": []}"#,
            callResult: #"{"content": [{"type": "text", "text": "a"}, {"type": "image", "data": "aW1n"}, {"type": "text", "text": "b"}], "isError": False}"#
        )
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        let result = try await connector.callTool(name: "echo", argumentsJSON: "{}")
        #expect(result == "a\nb")
    }

    @Test func toolEntryWithMissingNameBecomesEmptyString() async throws {
        // Pin current behavior: a tools/list entry without a string "name"
        // silently becomes a tool named "". If that default is ever made loud
        // (entry rejected), update this test deliberately.
        let fixture = try makeCustomResponseServer(
            listResult: #"{"tools": [{"description": "no name"}]}"#,
            callResult: #"{"content": [], "isError": False}"#
        )
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        let tools = try await connector.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "")
        #expect(tools.first?.description == "no name")
    }

    @Test func resultNullYieldsProtocolError() async throws {
        let fixture = try makeCustomResponseServer(
            listResult: "None",
            callResult: #"{"content": [], "isError": False}"#
        )
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.listTools()
            Issue.record("expected protocolError")
        } catch ToolConnectorError.protocolError(let message) {
            #expect(message.contains("result"))
        }
    }

    // MARK: - Adversarial: failure recovery and races

    @Test func validJSONNotificationFloodIsBoundedByTimeout() async throws {
        // readResponseLine skips valid-JSON lines without a matching id
        // *unboundedly* (only non-JSON lines count against the skip cap), so
        // only the request timeout bounds a notification flood. Pin that.
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
            if msg.get("method") == "initialize":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "0.0.1"}}}
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
                while True:
                    sys.stdout.write('{"jsonrpc": "2.0", "method": "notifications/spam"}' + "\\n")
                    sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 1)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.listTools()
            Issue.record("expected timeout under notification flood")
        } catch ToolConnectorError.timeout {
        }
    }

    @Test func initializeErrorLeavesConnectorRespawnable() async throws {
        // A JSON-RPC error on initialize does not terminate the process (only
        // timeout/protocolError do). Pin that the half-started connector
        // re-handshakes on the same process and recovers.
        let script = """
        import sys, json

        initialize_failed = False
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
                if not initialize_failed:
                    initialize_failed = True
                    resp = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": "init rejected"}}
                else:
                    resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "0.0.1"}}}
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.listTools()
            Issue.record("expected serverError from rejected initialize")
        } catch ToolConnectorError.serverError(let message) {
            #expect(message == "init rejected")
        }

        let tools = try await connector.listTools()
        #expect(tools.map(\.name) == ["echo"])
    }

    @Test func timeoutThenNextCallRespawnsFreshServer() async throws {
        // The first spawned process hangs forever (leaving a marker file);
        // after the timeout the connector must terminate it, and the next call
        // must respawn a fresh process that then serves normally.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-tools-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = """
        import sys, json, os, time

        if not os.path.exists("\(marker.path)"):
            open("\(marker.path)", "w").write("x")
            time.sleep(60)

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
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 1)
        defer { Task { await connector.terminate() } }

        do {
            _ = try await connector.listTools()
            Issue.record("expected timeout from hung first process")
        } catch ToolConnectorError.timeout {
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let tools = try await connector.listTools()
        #expect(tools.map(\.name) == ["echo"])
    }

    @Test func terminateDuringInFlightCallDoesNotCrashAndResets() async throws {
        // terminate() bypasses the single-flight gate by design; pin that
        // racing it against an in-flight call fails the call with
        // protocolError (never a crash) and leaves the connector respawnable.
        let script = """
        import sys, json, time

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
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}}
            elif method == "tools/call":
                time.sleep(60)
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "too late"}], "isError": False}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        let inFlight = Task { () -> String in
            do {
                _ = try await connector.callTool(name: "echo", argumentsJSON: "{}")
                return "unexpected success"
            } catch ToolConnectorError.protocolError {
                return "protocolError"
            } catch {
                return "other: \(error)"
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await connector.terminate()

        let outcome = await inFlight.value
        #expect(outcome == "protocolError")

        let tools = try await connector.listTools()
        #expect(tools.map(\.name) == ["echo"])
    }

    @Test func concurrentListAndCallStaySerialized() async throws {
        // Mixed barrage from cold state: the single-flight gate must serialize
        // every operation and the handshake must run exactly once.
        let countFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-tools-initcount-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: countFile) }
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
                with open("\(countFile.path)", "a") as f:
                    f.write("i\\n")
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "0.0.1"}}}
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}}
            elif method == "tools/call":
                resp = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "ok"}], "isError": False}}
            else:
                resp = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown method"}}
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        let fixture = try makeCustomServer(script)
        defer { fixture.cleanup() }
        let connector = MCPToolConnector(command: fixture.command, timeout: 10)
        defer { Task { await connector.terminate() } }

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask { try await connector.callTool(name: "echo", argumentsJSON: "{}") }
                group.addTask { try await connector.listTools().map(\.name).joined(separator: ",") }
            }
            for try await _ in group {
            }
        }

        let contents = try String(contentsOf: countFile, encoding: .utf8)
        #expect(contents.split(separator: "\n").count == 1)
    }
}
