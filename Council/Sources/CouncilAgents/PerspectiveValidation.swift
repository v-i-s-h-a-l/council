import Foundation

public enum PerspectiveValidationError: Error, Sendable {
    case verdictLanguageDetected
    case emptyDissent
    case invalidJSON
    case missingFields
    case unknown
}

extension PerspectiveValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .verdictLanguageDetected:
            return "Verdict language detected in perspective."
        case .emptyDissent:
            return "Dissent array is empty."
        case .invalidJSON:
            return "Perspective could not be parsed as JSON."
        case .missingFields:
            return "Perspective is missing required fields."
        case .unknown:
            return "Unknown perspective validation failure."
        }
    }
}
