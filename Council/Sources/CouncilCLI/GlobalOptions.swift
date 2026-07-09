import ArgumentParser
import Foundation

/// Options shared across all `council` subcommands.
struct GlobalOptions: ParsableArguments {
    @Option(help: "Directory for profile vault, memory database, and audit log.")
    var profileDir: String?

    @Flag(help: "Print progress and diagnostics to stderr.")
    var verbose = false

    @Option(help: "Output format: text, markdown, or json.")
    var format: CLIOutputFormat = .text
}
