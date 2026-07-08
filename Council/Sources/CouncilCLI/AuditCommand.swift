import ArgumentParser
import CouncilAgents
import CouncilCore
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Inspect and verify the audit log.",
        subcommands: [ListCommand.self, VerifyCommand.self]
    )
}

// MARK: - List

@available(macOS 14.0, iOS 17.0, *)
extension AuditCommand {
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List audit log entries."
        )

        @OptionGroup
        var options: GlobalOptions

        @Option(help: "Only include entries on or after this ISO8601 timestamp.")
        var since: String?

        @Option(help: "Maximum number of entries to return.")
        var limit: Int?

        @Flag(help: "Include decrypted payloads in the output.")
        var includePayloads = false

        func run() async throws {
            let sinceDate: Date?
            if let since {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                guard let date = formatter.date(from: since) ?? ISO8601DateFormatter().date(from: since) else {
                    throw ValidationError("--since must be an ISO8601 timestamp.")
                }
                sinceDate = date
            } else {
                sinceDate = nil
            }

            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let entries = try await assembly.memoryService.auditLog.entries(
                since: sinceDate,
                limit: limit,
                includePayloads: includePayloads
            )
            switch options.format {
            case .text, .markdown:
                for entry in entries {
                    let session = entry.sessionID.map { " \($0)" } ?? ""
                    print("\(entry.timestamp)\t\(entry.category.rawValue)\t\(entry.id)\(session)")
                    if includePayloads && !entry.payload.isEmpty {
                        for (key, value) in entry.payload.sorted(by: { $0.key < $1.key }) {
                            print("  \(key): \(value)")
                        }
                    }
                }
            case .json:
                print(try CLIEncoder.json(entries))
            }
        }
    }
}

// MARK: - Verify

@available(macOS 14.0, iOS 17.0, *)
extension AuditCommand {
    struct VerifyCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Verify the integrity of the audit chain."
        )

        @OptionGroup
        var options: GlobalOptions

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let valid = try await assembly.memoryService.verifyAuditChain()
            switch options.format {
            case .text, .markdown:
                print(valid ? "audit chain valid" : "audit chain INVALID")
            case .json:
                print(try CLIEncoder.json(["valid": valid]))
            }
            if !valid {
                throw ExitCode(1)
            }
        }
    }
}
