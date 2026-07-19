import CouncilCore
import Foundation

/// A least-privilege grant for tool access.
///
/// A grant binds tool usage to PBAC purposes (the same vocabulary as ADR-026).
/// Without a grant, a connector refuses every operation before any server
/// process is spawned — least privilege by construction.
public struct ToolGrant: Sendable {
    /// Purposes this grant is issued for. An empty set denies everything.
    public var purposes: [AccessPurpose]
    /// Tool names the grant covers; `nil` means all tools from the server.
    public var allowedTools: [String]?

    public init(purposes: [AccessPurpose], allowedTools: [String]? = nil) {
        self.purposes = purposes
        self.allowedTools = allowedTools
    }
}

/// A single tool-access decision, reported for audit logging.
public struct ToolAccessDecision: Sendable {
    public var operation: String
    public var toolName: String?
    public var purposes: [AccessPurpose]
    public var allowed: Bool

    public init(operation: String, toolName: String?, purposes: [AccessPurpose], allowed: Bool) {
        self.operation = operation
        self.toolName = toolName
        self.purposes = purposes
        self.allowed = allowed
    }
}

/// Wraps a connector and enforces a `ToolGrant` before every operation.
///
/// Denials are decided locally — the wrapped connector (and therefore any
/// server process) is never touched for a denied operation. Every decision is
/// reported through `onDecision` so the caller can write it to the audit chain.
public struct GrantEnforcingConnector: ToolConnector {
    private let connector: any ToolConnector
    private let grant: ToolGrant
    private let onDecision: @Sendable (ToolAccessDecision) -> Void

    public init(
        connector: any ToolConnector,
        grant: ToolGrant,
        onDecision: @escaping @Sendable (ToolAccessDecision) -> Void = { _ in }
    ) {
        self.connector = connector
        self.grant = grant
        self.onDecision = onDecision
    }

    public func listTools() async throws -> [ToolDescriptor] {
        try require(operation: "listTools", toolName: nil)
        let tools = try await connector.listTools()
        // Discovery is filtered to the grant as well: an allowlisted grant
        // must not learn about tools it cannot invoke.
        guard let allowedTools = grant.allowedTools else { return tools }
        return tools.filter { allowedTools.contains($0.name) }
    }

    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        try require(operation: "callTool", toolName: name)
        return try await connector.callTool(name: name, argumentsJSON: argumentsJSON)
    }

    private func require(operation: String, toolName: String?) throws {
        let deniedReason: String?
        if grant.purposes.isEmpty {
            deniedReason = "grant has no purposes"
        } else if let allowedTools = grant.allowedTools,
                  let toolName,
                  !allowedTools.contains(toolName) {
            deniedReason = "tool '\(toolName)' is not in the grant's allowlist"
        } else {
            deniedReason = nil
        }

        let allowed = deniedReason == nil
        onDecision(ToolAccessDecision(
            operation: operation,
            toolName: toolName,
            purposes: grant.purposes,
            allowed: allowed
        ))
        if let deniedReason {
            throw ToolConnectorError.accessDenied(deniedReason)
        }
    }
}
