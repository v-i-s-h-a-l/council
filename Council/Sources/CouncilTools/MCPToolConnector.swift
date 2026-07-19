import Foundation

/// MCP (Model Context Protocol) client speaking JSON-RPC 2.0 over stdio.
///
/// The server is spawned lazily on first use as a child process via `/bin/sh -c`
/// and is expected to exit when stdin closes. Requests are serialized by actor
/// isolation; every request is bounded by `timeout` so a hung server cannot
/// wedge the caller.
///
/// Process spawning is only available on macOS/Linux; on other platforms every
/// operation throws ``ToolConnectorError/unsupportedPlatform(_:)``.
public actor MCPToolConnector: ToolConnector {
    private let command: String
    private let timeout: TimeInterval

    public init(command: String, timeout: TimeInterval = 30) {
        self.command = command
        self.timeout = timeout
    }

    #if os(macOS) || os(Linux)
    // MARK: - State

    private var process: Process?
    private var stdin: Pipe?
    private var lineReader: MCPLineReader?
    private var initialized = false
    private var nextID = 1

    // MARK: - ToolConnector

    public func listTools() async throws -> [ToolDescriptor] {
        try await ensureStarted()
        let result = try await request(method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw ToolConnectorError.protocolError("tools/list response missing 'tools' array")
        }
        return tools.map { entry in
            let schema = entry["inputSchema"]
            let schemaString = (try? JSONSerialization.data(withJSONObject: schema ?? NSNull()))
                .flatMap { String(data: $0, encoding: .utf8) }
            return ToolDescriptor(
                name: entry["name"] as? String ?? "",
                description: entry["description"] as? String,
                inputSchema: schemaString
            )
        }
    }

    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        try await ensureStarted()
        let arguments: Any
        if argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments = [String: Any]()
        } else {
            let data = Data(argumentsJSON.utf8)
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let object = parsed as? [String: Any] else {
                throw ToolConnectorError.protocolError("arguments must be a JSON object")
            }
            arguments = object
        }
        let result = try await request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ])
        if let isError = result["isError"] as? Bool, isError {
            throw ToolConnectorError.serverError(Self.textContent(from: result))
        }
        return Self.textContent(from: result)
    }

    /// Terminates the server process. Safe to call multiple times.
    public func terminate() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdin = nil
        lineReader = nil
        initialized = false
    }

    /// Builds a newline-delimited line stream over a pipe's read handle using
    /// `readabilityHandler` (GCD), so delivery never parks a Swift concurrency
    /// cooperative-pool thread in a blocking read the way `FileHandle.AsyncBytes`
    /// can under parallel test load.
    static func makeLineStream(from handle: FileHandle) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let buffer = MCPLineBuffer()
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    fileHandle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in buffer.append(data) {
                    continuation.yield(line)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    // MARK: - Lifecycle

    private func ensureStarted() async throws {
        if initialized { return }
        if process == nil {
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            do {
                try process.run()
            } catch {
                throw ToolConnectorError.spawnFailed("\(command): \(error.localizedDescription)")
            }
            self.process = process
            self.stdin = stdinPipe
            self.lineReader = MCPLineReader(Self.makeLineStream(from: stdoutPipe.fileHandleForReading))
        }
        // MCP handshake: initialize, then the initialized notification.
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "council-cli", "version": "0.1.0"],
        ])
        try send(json: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ])
        initialized = true
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try send(json: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        // The raw line (Sendable) crosses the timeout task group; JSON parsing
        // happens here on the actor.
        let line: String
        do {
            line = try await withTimeout(seconds: timeout, method: method) { [self] in
                try await readResponseLine(id: id)
            }
        } catch ToolConnectorError.timeout {
            // Killing the server closes the pipe, which unblocks the read task
            // still parked in the cancelled group child.
            terminate()
            throw ToolConnectorError.timeout("no response to '\(method)' within \(Int(timeout))s")
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolConnectorError.protocolError("response is not a JSON object")
        }
        if let error = message["error"] as? [String: Any] {
            let messageText = error["message"] as? String ?? "unknown JSON-RPC error"
            throw ToolConnectorError.serverError(messageText)
        }
        guard let result = message["result"] as? [String: Any] else {
            throw ToolConnectorError.protocolError("response missing 'result' object")
        }
        return result
    }

    private func send(json: [String: Any]) throws {
        guard let stdin else {
            throw ToolConnectorError.protocolError("server stdin is not available")
        }
        var line = try JSONSerialization.data(withJSONObject: json)
        line.append(0x0A) // newline-delimited JSON-RPC
        try stdin.fileHandleForWriting.write(contentsOf: line)
    }

    /// Reads newline-delimited messages until the response line with the matching
    /// id arrives, skipping notifications and non-JSON lines.
    private func readResponseLine(id: Int) async throws -> String {
        var skipped = 0
        while true {
            guard let reader = lineReader else {
                throw ToolConnectorError.protocolError("server stdout is not available")
            }
            guard let line = try await reader.next() else {
                throw ToolConnectorError.protocolError("server closed stdout before responding")
            }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                skipped += 1
                if skipped > 100 {
                    throw ToolConnectorError.protocolError("too many non-JSON lines from server")
                }
                continue
            }
            if let responseID = message["id"] as? Int, responseID == id {
                return line
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ToolConnectorError.timeout("no response to '\(method)' within \(Int(seconds))s")
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw ToolConnectorError.protocolError("empty task group")
            }
            group.cancelAll()
            return result
        }
    }

    private static func textContent(from result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        return content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    #else
    // MARK: - Unsupported platforms

    public func listTools() async throws -> [ToolDescriptor] {
        throw ToolConnectorError.unsupportedPlatform("tool servers require macOS or Linux")
    }

    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        throw ToolConnectorError.unsupportedPlatform("tool servers require macOS or Linux")
    }

    public func terminate() {}
    #endif
}

#if os(macOS) || os(Linux)
/// Owns the line-stream iterator so its non-Sendable mutation state never crosses
/// a suspension point. Marked @unchecked Sendable: access is serialized by the
/// owning actor.
final class MCPLineReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<String, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}

/// Lock-guarded buffer that splits inbound pipe data into newline-delimited lines.
final class MCPLineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newlineIndex = data.firstIndex(of: 0x0A) {
            if let line = String(data: data[data.startIndex..<newlineIndex], encoding: .utf8) {
                lines.append(line)
            }
            // Rebase through Data(...) so indices always start at zero.
            data = Data(data[data.index(after: newlineIndex)...])
        }
        return lines
    }
}
#endif
