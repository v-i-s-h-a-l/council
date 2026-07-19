import Foundation

/// A tool exposed by an external tool server.
public struct ToolDescriptor: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// Raw JSON schema for the tool's input, as advertised by the server.
    public var inputSchema: String?

    public init(name: String, description: String? = nil, inputSchema: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A connector to an external tool server (e.g. an MCP server over stdio).
///
/// Connectors are always used behind a ``GrantEnforcingConnector`` so that
/// least-privilege `ToolGrant` checks happen before any server process is
/// spawned or invoked. Every decision (allow/deny) is reported through the
/// `onDecision` callback so callers can record it in the audit chain.
public protocol ToolConnector: Sendable {
    /// Discovers the tools the server exposes.
    func listTools() async throws -> [ToolDescriptor]

    /// Invokes a tool by name with a raw JSON object of arguments, returning the
    /// server's textual result.
    func callTool(name: String, argumentsJSON: String) async throws -> String
}

/// Errors thrown by tool connectors and grant enforcement.
public enum ToolConnectorError: Error, Sendable, Equatable {
    /// The tool grant does not permit this operation. No server process was spawned.
    case accessDenied(String)
    /// The server process could not be started.
    case spawnFailed(String)
    /// The server violated the JSON-RPC/MCP protocol.
    case protocolError(String)
    /// The server did not respond within the allotted time.
    case timeout(String)
    /// The server returned an error response.
    case serverError(String)
    /// Tool servers are not supported on this platform.
    case unsupportedPlatform(String)
}
