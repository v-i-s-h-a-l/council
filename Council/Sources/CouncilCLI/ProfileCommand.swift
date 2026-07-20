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
        subcommands: [ShowCommand.self, ValueCommand.self, GoalCommand.self, BoundaryCommand.self, JournalCommand.self]
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
                print(formatProfileShowText(profile))
            case .json:
                let context = RoutableProfileContext(profile: profile)
                print(try CLIEncoder.json(context))
            }
        }
    }
}

/// Renders the profile for `profile show` text output. Journal entries and
/// financial history are confidential: only their counts are ever shown,
/// never their contents.
func formatProfileShowText(_ profile: UserProfile) -> String {
    var lines: [String] = []
    lines.append("Values:")
    for value in profile.values {
        let tags = value.tags.isEmpty ? "" : " [\(value.tags.joined(separator: ", "))]"
        lines.append("  \(value.id): \(value.text)\(tags)")
    }
    lines.append("")
    lines.append("Goals:")
    for goal in profile.goals {
        let timeframe = goal.timeframe.map { " (\($0))" } ?? ""
        let status = goal.status.map { " [\($0.rawValue)]" } ?? ""
        let tags = goal.tags.isEmpty ? "" : " [\(goal.tags.joined(separator: ", "))]"
        lines.append("  \(goal.id): \(goal.text)\(timeframe)\(status)\(tags)")
    }
    lines.append("")
    lines.append("Boundaries:")
    for boundary in profile.boundaries {
        let severity = boundary.severity.map { " [\($0.rawValue)]" } ?? ""
        let tags = boundary.tags.isEmpty ? "" : " [\(boundary.tags.joined(separator: ", "))]"
        lines.append("  \(boundary.id): \(boundary.text)\(severity)\(tags)")
    }
    lines.append("")
    lines.append("Journal: \(profile.journalEntries.count) confidential entr\(profile.journalEntries.count == 1 ? "y" : "ies") (use `profile journal` to inspect)")
    lines.append("Financial: \(profile.financialHistory.items.count) confidential record\(profile.financialHistory.items.count == 1 ? "" : "s")")
    return lines.joined(separator: "\n")
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

        @Option(name: .shortAndLong, help: "Tag to attach to the value. May be repeated.")
        var tag: [String] = []

        @Option(name: .long, help: "Purpose the value is routable for. May be repeated. Defaults to all deliberation purposes.")
        var purpose: [AccessPurpose] = []

        @Option(name: .long, help: "Purpose explicitly denied for this value. May be repeated.")
        var deniedPurpose: [AccessPurpose] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let statement = try await assembly.profileService.addValue(
                text,
                tags: tag,
                accessScope: purpose.isEmpty ? AccessPurpose.allDeliberation : purpose,
                deniedPurposes: deniedPurpose
            )
            try printOutput(id: statement.id, format: options.format)
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

        @Option(name: .shortAndLong, help: "Tag to attach to the goal. May be repeated.")
        var tag: [String] = []

        @Option(help: "Goal status: active, completed, or paused.")
        var status: GoalStatus?

        @Option(name: .long, help: "Purpose the goal is routable for. May be repeated. Defaults to all deliberation purposes.")
        var purpose: [AccessPurpose] = []

        @Option(name: .long, help: "Purpose explicitly denied for this goal. May be repeated.")
        var deniedPurpose: [AccessPurpose] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let goal = try await assembly.profileService.addGoal(
                text,
                timeframe: timeframe,
                tags: tag,
                status: status,
                accessScope: purpose.isEmpty ? AccessPurpose.allDeliberation : purpose,
                deniedPurposes: deniedPurpose
            )
            try printOutput(id: goal.id, format: options.format)
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

        @Option(name: .shortAndLong, help: "Tag to attach to the boundary. May be repeated.")
        var tag: [String] = []

        @Option(help: "Boundary severity: low, medium, high, or critical.")
        var severity: BoundarySeverity?

        @Option(name: .long, help: "Purpose the boundary is routable for. May be repeated. Defaults to all deliberation purposes.")
        var purpose: [AccessPurpose] = []

        @Option(name: .long, help: "Purpose explicitly denied for this boundary. May be repeated.")
        var deniedPurpose: [AccessPurpose] = []

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let boundary = try await assembly.profileService.addBoundary(
                text,
                tags: tag,
                severity: severity,
                accessScope: purpose.isEmpty ? AccessPurpose.allDeliberation : purpose,
                deniedPurposes: deniedPurpose
            )
            try printOutput(id: boundary.id, format: options.format)
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

// MARK: - Journal

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand {
    struct JournalCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "journal",
            abstract: "Manage confidential journal entries.",
            subcommands: [AddCommand.self, ListCommand.self, RemoveCommand.self]
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ProfileCommand.JournalCommand {
    struct AddCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a confidential journal entry. Reads from <text> if provided, otherwise from standard input."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The journal entry text. If omitted, reads from standard input.")
        var text: String?

        @Flag(name: .long, help: "Read the entry body from standard input.")
        var stdin: Bool = false

        @Option(name: .shortAndLong, help: "Tag to attach to the entry. May be repeated.")
        var tag: [String] = []

        @Option(name: .shortAndLong, help: "Entry creation date in ISO-8601 format (defaults to now).")
        var date: String?

        func run() async throws {
            let body: String
            if stdin || text == nil {
                body = try readStdin()
            } else {
                body = try validatedJournalBody(text!)
            }

            let createdAt: Date
            if let date {
                createdAt = try parseISODate(date)
            } else {
                createdAt = Date()
            }

            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            let entry = try await assembly.profileService.addJournalEntry(
                body,
                createdAt: createdAt,
                tags: tag
            )
            try printOutput(id: entry.id, format: options.format)
        }
    }

    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List confidential journal entries. Full text is redacted unless --reveal is passed."
        )

        @OptionGroup
        var options: GlobalOptions

        @Option(name: .shortAndLong, help: "Tag to filter by. Multiple tags use AND semantics.")
        var tag: [String] = []

        @Option(name: .long, help: "Include entries created on or after this ISO-8601 date.")
        var from: String?

        @Option(name: .long, help: "Include entries created on or before this ISO-8601 date.")
        var to: String?

        @Flag(name: .long, help: "Reveal full entry text in the output.")
        var reveal: Bool = false

        @Option(name: .shortAndLong, help: "Maximum number of entries to show.")
        var limit: Int?

        func validate() throws {
            // A negative limit silently yields no entries, which makes
            // `formatJournalListText` print the misleading "No journal entries."
            if let limit, limit < 0 {
                throw ValidationError("--limit must be greater than or equal to 0.")
            }
        }

        func run() async throws {
            let fromDate = try from.map { try parseISODate($0) }
            let toDate = try to.map { try parseISODate($0) }

            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            var entries = try await assembly.profileService.journalEntries(
                tags: tag,
                from: fromDate,
                to: toDate
            )
            if let limit {
                entries = Array(entries.prefix(limit))
            }

            switch options.format {
            case .text, .markdown:
                print(formatJournalListText(entries: entries, reveal: reveal))
            case .json:
                print(try CLIEncoder.json(presentJournalListItems(entries: entries, reveal: reveal)))
            }
        }
    }

    struct RemoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a journal entry by ID."
        )

        @OptionGroup
        var options: GlobalOptions

        @Argument(help: "The journal entry UUID.")
        var id: UUID

        func run() async throws {
            let assembly = try await CLIAssembly.makeRuntimeAssembly(options: options)
            try await assembly.profileService.removeJournalEntry(id: id)
        }
    }
}

// MARK: - Helpers

@available(macOS 14.0, iOS 17.0, *)
private func printOutput(id: UUID, format: CLIOutputFormat) throws {
    switch format {
    case .text, .markdown:
        print(id.uuidString)
    case .json:
        print(try CLIEncoder.json(["id": id.uuidString]))
    }
}

private func readStdin() throws -> String {
    var input = ""
    while let line = readLine(strippingNewline: false) {
        input.append(line)
    }
    return try validatedJournalBody(input)
}

/// Returns the journal body unchanged, rejecting empty or whitespace-only
/// input so a stray pipe or blank argument cannot create an empty
/// confidential entry.
func validatedJournalBody(_ input: String) throws -> String {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("Journal entry text is required.")
    }
    return input
}

func parseISODate(_ value: String) throws -> Date {
    // Accept fractional seconds for parity with `audit list --since`.
    let withFractionalSeconds = ISO8601DateFormatter()
    withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = withFractionalSeconds.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
        throw ValidationError("Invalid date format: expected ISO-8601 (e.g., 2026-07-09T12:00:00Z).")
    }
    return date
}

private struct ValidationError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}

func presentJournalListItems(entries: [JournalEntry], reveal: Bool) -> [JournalListItem] {
    entries.map { entry in
        JournalListItem(
            id: entry.id,
            createdAt: entry.createdAt,
            tags: entry.tags,
            text: reveal ? entry.text : nil
        )
    }
}

func formatJournalListText(entries: [JournalEntry], reveal: Bool) -> String {
    var lines: [String] = []
    if entries.isEmpty {
        lines.append("No journal entries.")
    } else {
        for entry in entries {
            let tags = entry.tags.isEmpty ? "" : " [\(entry.tags.joined(separator: ", "))]"
            let textLine = reveal ? " \(entry.text)" : " (text redacted)"
            lines.append("\(entry.createdAt.iso8601) \(entry.id)\(tags)\(textLine)")
        }
    }
    return lines.joined(separator: "\n")
}

struct JournalListItem: Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var tags: [String]
    var text: String?
}

private extension Date {
    var iso8601: String {
        ISO8601DateFormatter().string(from: self)
    }
}
