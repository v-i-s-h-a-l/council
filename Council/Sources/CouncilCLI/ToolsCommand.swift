import ArgumentParser
import CouncilAgents
import CouncilCore
import CouncilMemory
import CouncilTools
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Discover and invoke tools on external MCP tool servers.",
        subcommands: [ListCommand.self, CallCommand.self]
    )
}

@available(macOS 14.0, iOS 17.0, *)
extension ToolsCommand {
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the tools an MCP server exposes."
        )

        @OptionGroup
        var options: GlobalOptions

        @Option(name: .long, help: "Shell command that starts the MCP server (stdio transport).")
        var server: String

        @Option(name: .long, help: "Purpose the grant is issued for. May be repeated. Defaults to userInspection.")
        var purpose: [AccessPurpose] = []

        @Option(name: .long, help: "Restrict the grant to these tool names. May be repeated.")
        var tool: [String] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let box = DecisionBox()
            let connector = MCPToolConnector(command: server)
            let granted = GrantEnforcingConnector(
                connector: connector,
                grant: ToolGrant(
                    purposes: purpose.isEmpty ? [.userInspection] : purpose,
                    allowedTools: tool.isEmpty ? nil : tool
                ),
                onDecision: { box.append($0) }
            )

            do {
                let tools = try await granted.listTools()
                await connector.terminate()
                await audit(decisions: box.decisions, assembly: assembly, server: server)
                switch options.format {
                case .text, .markdown:
                    if tools.isEmpty {
                        print("No tools exposed by the server.")
                    } else {
                        for descriptor in tools {
                            let description = descriptor.description.map { " — \($0)" } ?? ""
                            print("\(descriptor.name)\(description)")
                        }
                    }
                case .json:
                    print(try CLIEncoder.json(tools))
                }
            } catch {
                await connector.terminate()
                await audit(decisions: box.decisions, assembly: assembly, server: server)
                throw error
            }
        }
    }

    struct CallCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "call",
            abstract: "Invoke a tool on an MCP server."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The tool name to invoke.")
        var name: String

        @Option(name: .long, help: "Shell command that starts the MCP server (stdio transport).")
        var server: String

        @Option(name: .long, help: "JSON object of tool arguments.")
        var args: String = "{}"

        @Option(name: .long, help: "Purpose the grant is issued for. May be repeated. Defaults to userInspection.")
        var purpose: [AccessPurpose] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let box = DecisionBox()
            let connector = MCPToolConnector(command: server)
            let granted = GrantEnforcingConnector(
                connector: connector,
                grant: ToolGrant(
                    purposes: purpose.isEmpty ? [.userInspection] : purpose,
                    allowedTools: [name]
                ),
                onDecision: { box.append($0) }
            )

            do {
                let result = try await granted.callTool(name: name, argumentsJSON: args)
                await connector.terminate()
                await audit(decisions: box.decisions, assembly: assembly, server: server)
                switch options.format {
                case .text, .markdown:
                    print(result)
                case .json:
                    print(try CLIEncoder.json(["tool": name, "result": result]))
                }
            } catch {
                await connector.terminate()
                await audit(decisions: box.decisions, assembly: assembly, server: server)
                throw error
            }
        }
    }
}

// MARK: - Audit helpers

/// Collects grant decisions. The connector invokes `onDecision` synchronously on
/// the caller's task before each operation, so no synchronization is needed.
private final class DecisionBox: @unchecked Sendable {
    private(set) var decisions: [ToolAccessDecision] = []
    func append(_ decision: ToolAccessDecision) { decisions.append(decision) }
}

private func audit(
    decisions: [ToolAccessDecision],
    assembly: RuntimeAssembly,
    server: String
) async {
    // Log only the executable basename, never the full command line: commands
    // may embed environment variables or arguments that must not persist in
    // the audit chain.
    let serverLabel = URL(fileURLWithPath: server.split(separator: " ").first.map(String.init) ?? server)
        .lastPathComponent
    for decision in decisions {
        var payload: [String: String] = [
            "server": serverLabel,
            "operation": decision.operation,
            "decision": decision.allowed ? "allowed" : "denied",
            "purpose": decision.purposes.map(\.rawValue).sorted().joined(separator: ","),
        ]
        if let toolName = decision.toolName {
            payload["tool"] = toolName
        }
        do {
            try await assembly.memoryService.appendAuditEntry(
                category: .toolCall,
                payload: payload
            )
        } catch {
            FileHandle.standardError.write(
                Data("council: warning: tool-call audit entry failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }
}
