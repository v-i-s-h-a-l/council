import XCTest
import CouncilCore
@testable import CouncilInference

final class EchoInferenceProviderAdversarialTests: XCTestCase {
    /// The echo provider's canned literal claims to be schema-compliant and
    /// the CLI decodes it as `Perspective`. Any edit that breaks the shape
    /// must fail here rather than at CLI parse time.
    func testCannedResponseDecodesAsPerspective() async throws {
        let provider = EchoInferenceProvider()
        let stream = try await provider.generate(
            messages: [InferenceMessage(role: .user, content: "ping")],
            options: InferenceOptions()
        )

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.count, 1, "Echo provider must yield exactly one chunk, then finish")

        let perspective = try JSONDecoder().decode(
            Perspective.self,
            from: Data(chunks[0].utf8)
        )
        XCTAssertFalse(perspective.summary.isEmpty)
        XCTAssertFalse(perspective.tradeOffs.isEmpty)
        XCTAssertFalse(perspective.blindSpots.isEmpty)
        XCTAssertFalse(perspective.dissent.isEmpty)
    }

    /// A deterministic provider must never incorporate prompt content into
    /// its output — including user data supplied in messages.
    func testResponseDoesNotIncorporatePromptContent() async throws {
        let provider = EchoInferenceProvider()

        func collect(_ messages: [InferenceMessage]) async throws -> [String] {
            let stream = try await provider.generate(messages: messages, options: InferenceOptions())
            var chunks: [String] = []
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return chunks
        }

        let secret = "confidential-user-data-0123"
        let withSecret = try await collect([InferenceMessage(role: .user, content: secret)])
        let withoutSecret = try await collect([InferenceMessage(role: .user, content: "unrelated")])

        XCTAssertEqual(withSecret, withoutSecret)
        XCTAssertFalse(withSecret.joined().contains(secret))
    }

    func testRouteSnapshotValues() async {
        let provider = EchoInferenceProvider()
        let snapshot = await provider.routeSnapshot
        XCTAssertEqual(snapshot.framework, "echo")
        XCTAssertEqual(snapshot.modelIdentifier, "echo")
        XCTAssertEqual(snapshot.route, .onDeviceApple)
        XCTAssertTrue(snapshot.isLocal)
    }
}
