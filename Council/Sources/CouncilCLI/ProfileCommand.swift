import ArgumentParser
import CouncilAgents
import CouncilCore
import CouncilMemory
import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage your Council profile.",
        subcommands: [ShowCommand.self, ValueCommand.self, GoalCommand.self, BoundaryCommand.self]
    )
}

// MARK: - Show

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand {
    struct ShowCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show the current profile."
        )

        @OptionGroup
        var options: GlobalOptions

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let profile = try await assembly.profileService.load()

            switch options.format {
            case .text, .markdown:
                var lines: [String] = []
                lines.append("Values:")
                for value in profile.values {
                    lines.append("  \(value.id): \(value.text)")
                }
                lines.append("")
                lines.append("Goals:")
                for goal in profile.goals {
                    let timeframe = goal.timeframe.map { " (\($0))" } ?? ""
                    lines.append("  \(goal.id): \(goal.text)\(timeframe)")
                }
                lines.append("")
                lines.append("Boundaries:")
                for boundary in profile.boundaries {
                    lines.append("  \(boundary.id): \(boundary.text)")
                }
                lines.append("")
                lines.append("Confidential containers: \(profile.financialHistory.items.count) financial, \(profile.journalExcerpts.items.count) journal")
                print(lines.joined(separator: "\n"))
            case .json:
                let context = RoutableProfileContext(profile: profile)
                print(try CLIEncoder.json(context))
            }
        }
    }
}

// MARK: - Value

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand {
    struct ValueCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "value",
            abstract: "Manage value statements.",
            subcommands: [AddCommand.self, RemoveCommand.self]
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand.ValueCommand {
    struct AddCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a value statement."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The value statement text.")
        var text: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let statement = try await assembly.profileService.addValue(text)
            printOutput(id: statement.id, format: options.format)
        }
    }

    struct RemoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a value statement by ID."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The value statement UUID.")
        var id: UUID

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            try await assembly.profileService.removeValue(id: id)
        }
    }
}

// MARK: - Goal

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand {
    struct GoalCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "goal",
            abstract: "Manage goals.",
            subcommands: [AddCommand.self, RemoveCommand.self]
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand.GoalCommand {
    struct AddCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a goal."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The goal text.")
        var text: String

        @Option(help: "Optional timeframe for the goal.")
        var timeframe: String?

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let goal = try await assembly.profileService.addGoal(text, timeframe: timeframe)
            printOutput(id: goal.id, format: options.format)
        }
    }

    struct RemoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a goal by ID."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The goal UUID.")
        var id: UUID

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            try await assembly.profileService.removeGoal(id: id)
        }
    }
}

// MARK: - Boundary

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand {
    struct BoundaryCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "boundary",
            abstract: "Manage boundaries.",
            subcommands: [AddCommand.self, RemoveCommand.self]
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand.BoundaryCommand {
    struct AddCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a boundary."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The boundary text.")
        var text: String

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let boundary = try await assembly.profileService.addBoundary(text)
            printOutput(id: boundary.id, format: options.format)
        }
    }

    struct RemoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a boundary by ID."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The boundary UUID.")
        var id: UUID

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            try await assembly.profileService.removeBoundary(id: id)
        }
    }
}

// MARK: - Output helper

@available(macOS 14.0, iOS 17.0, *)
private func printOutput(id: UUID, format: CLIOutputFormat) {
    switch format {
    case .text, .markdown:
        print(id.uuidString)
    case .json:
        print(try! CLIEncoder.json(["id": id.uuidString]))
    }
}
