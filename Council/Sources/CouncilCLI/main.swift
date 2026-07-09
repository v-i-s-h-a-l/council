import ArgumentParser
import Foundation

@main
@available(macOS 14.0, iOS 17.0, *)
struct CouncilCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "council",
        abstract: "A local, constitution-governed deliberation tool.",
        subcommands: [
            AskCommand.self,
            ProfileCommand.self,
            MemoryCommand.self,
            ModelCommand.self,
            AuditCommand.self,
        ],
        defaultSubcommand: AskCommand.self
    )
}
