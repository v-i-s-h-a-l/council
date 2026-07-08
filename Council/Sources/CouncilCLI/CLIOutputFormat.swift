import ArgumentParser
import Foundation

/// Output format shared by all `council` subcommands.
public enum CLIOutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case markdown
    case json
}
