import ArgumentParser
import CouncilAgents
import CouncilCore
import CouncilMemory
import Foundation

extension AccessPurpose: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage Council memory.",
        subcommands: [ListCommand.self, ShowCommand.self, SearchCommand.self, FactCommand.self]
    )
}

// MARK: - List

@available(macOS 14.0, iOS 17.0, *)
extension MemoryCommand {
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent episodic gists."
        )

        @OptionGroup
        var options: GlobalOptions

        @Option(help: "Maximum number of entries to return.")
        var limit: Int = 20

        func validate() throws {
            guard limit >= 0 else {
                throw ValidationError("--limit must be greater than or equal to 0.")
            }
        }

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let episodes = try await assembly.memoryService.recentEpisodes(limit: limit)
            try printEpisodes(episodes, format: options.format, includePerspective: false)
        }
    }
}

// MARK: - Show

@available(macOS 14.0, iOS 17.0, *)
extension MemoryCommand {
    struct ShowCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a single episodic gist."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The gist UUID.")
        var id: UUID

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            guard let episode = try await assembly.memoryService.episode(id: id) else {
                CLIAssembly.writeToStderr("No gist found with id \(id).\n")
                throw ExitCode(1)
            }
            try printEpisodes([episode], format: options.format, includePerspective: true)
        }
    }
}

// MARK: - Search

@available(macOS 14.0, iOS 17.0, *)
extension MemoryCommand {
    struct SearchCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search episodic gists by question substring."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The search query.")
        var query: String

        @Option(help: "Maximum number of entries to return.")
        var limit: Int = 20

        func validate() throws {
            guard limit >= 0 else {
                throw ValidationError("--limit must be greater than or equal to 0.")
            }
        }

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let episodes = try await assembly.memoryService.searchEpisodes(query: query, limit: limit)
            try printEpisodes(episodes, format: options.format, includePerspective: false)
        }
    }
}

// MARK: - Fact

@available(macOS 14.0, iOS 17.0, *)
extension MemoryCommand {
    struct FactCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fact",
            abstract: "Manage temporal facts.",
            subcommands: [AddCommand.self, ListCommand.self]
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension MemoryCommand.FactCommand {
    struct AddCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a temporal fact."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The fact subject.")
        var subject: String

        @Argument(help: "The fact predicate.")
        var predicate: String

        @Argument(help: "The fact object.")
        var object: String

        @Option(help: "Access purpose for the fact.")
        var purpose: AccessPurpose = .purchaseDeliberation

        @Option(name: .long, help: "Purpose explicitly denied for this fact. May be repeated.")
        var deniedPurpose: [AccessPurpose] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let fact = try await assembly.memoryService.addFact(
                subject: subject,
                predicate: predicate,
                object: object,
                accessScope: [purpose],
                deniedPurposes: deniedPurpose
            )
            switch options.format {
            case .text, .markdown:
                print(fact.id.uuidString)
            case .json:
                print(try CLIEncoder.json(["id": fact.id.uuidString]))
            }
        }
    }

    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List temporal facts."
        )

        @OptionGroup
        var options: GlobalOptions

        @Option(help: "Filter facts by subject.")
        var subject: String?

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let facts = try await assembly.memoryService.facts(subject: subject)
            switch options.format {
            case .text, .markdown:
                for fact in facts {
                    print("\(fact.id): \(fact.subject) \(fact.predicate) \(fact.object)")
                }
            case .json:
                print(try CLIEncoder.json(facts))
            }
        }
    }
}

// MARK: - Output helpers

@available(macOS 14.0, iOS 17.0, *)
private func printEpisodes(
    _ episodes: [EpisodicGist],
    format: CLIOutputFormat,
    includePerspective: Bool
) throws {
    switch format {
    case .text, .markdown:
        for episode in episodes {
            print("\(episode.id) | \(episode.createdAt) | \(episode.question)")
            if includePerspective {
                print(PerspectiveFormatter.text(episode.perspective))
            }
        }
    case .json:
        print(try episodeJSON(episodes, includePerspective: includePerspective))
    }
}

/// Renders episodes as JSON for `--format json` output.
///
/// This must never be a force-try: episode rows come from the persisted store,
/// and a tampered or corrupt row must surface as a thrown error, not crash the
/// process.
func episodeJSON(_ episodes: [EpisodicGist], includePerspective: Bool) throws -> String {
    let rows = episodes.map { episode in
        EpisodeRow(
            id: episode.id,
            sessionID: episode.sessionID,
            createdAt: episode.createdAt,
            question: episode.question,
            perspective: includePerspective ? episode.perspective : nil
        )
    }
    return try CLIEncoder.json(rows)
}

private struct EpisodeRow: Encodable {
    let id: UUID
    let sessionID: UUID
    let createdAt: Date
    let question: String
    let perspective: Perspective?
}
