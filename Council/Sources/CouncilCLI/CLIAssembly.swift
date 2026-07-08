import CouncilAgents
import Foundation

/// UI-agnostic helper that creates a `RuntimeAssembly` from CLI global options.
@available(macOS 14.0, iOS 17.0, *)
enum CLIAssembly {
    /// Errors that can occur while resolving the CLI profile directory.
    enum AssemblyError: Error {
        case missingApplicationSupportDirectory
        case cannotResolveProfileDirectory
    }

    /// Creates a `RuntimeAssembly` rooted at the directory specified by global options.
    static func makeRuntimeAssembly(options: GlobalOptions) async throws -> RuntimeAssembly {
        let directory = try resolveProfileDirectory(path: options.profileDir)

        if options.verbose {
            writeToStderr("Using profile directory: \(directory.path)\n")
        }

        let assembly = try await RuntimeAssembly(
            rootDirectory: directory,
            useSecureEnclave: false
        )

        try hardenProfileDirectory(at: directory)

        return assembly
    }

    /// Resolves an explicit profile directory or falls back to Application Support/Council.
    static func resolveProfileDirectory(path: String?) throws -> URL {
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty else {
                throw AssemblyError.cannotResolveProfileDirectory
            }
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return url
        }

        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AssemblyError.missingApplicationSupportDirectory
        }
        let url = appSupport.appendingPathComponent("Council", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return url
    }

    /// Enforces owner-only permissions on the profile directory and key files.
    private static func hardenProfileDirectory(at url: URL) throws {
        let fm = FileManager.default
        try fm.setAttributes(
            [FileAttributeKey.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )

        let sensitiveFiles = [
            "profile.key",
            "salt.bin",
            "memory.sqlite",
            "memory.sqlite.audit",
            "vault.enc",
        ]
        for name in sensitiveFiles {
            let fileURL = url.appendingPathComponent(name)
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            try fm.setAttributes(
                [FileAttributeKey.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    static func writeToStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
