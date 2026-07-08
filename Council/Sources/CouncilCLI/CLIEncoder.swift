import Foundation

/// Errors that can occur while encoding CLI JSON output.
enum CLIEncoderError: Error {
    case stringEncodingFailed
}

/// Shared JSON encoder for CLI `--format json` output.
enum CLIEncoder {
    static let shared: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try shared.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIEncoderError.stringEncodingFailed
        }
        return string
    }
}
