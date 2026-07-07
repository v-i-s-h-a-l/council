import Foundation

public enum ConstitutionLoader {
    public static func loadBundledText() throws -> String {
        guard let url = Bundle.module.url(forResource: "Constitution", withExtension: "md") else {
            throw ConstitutionError.notFound
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum ConstitutionError: Error, Sendable {
    case notFound
}
