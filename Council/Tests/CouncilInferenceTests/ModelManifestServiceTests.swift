import XCTest
@testable import CouncilInference

final class ModelManifestServiceTests: XCTestCase {
    func testConsentGrantAndRevoke() async {
        let service = ModelManifestService()

        await service.grantConsent(id: "model-a")
        let consented = await service.isModelConsented(id: "model-a")
        XCTAssertTrue(consented)

        await service.revokeConsent(id: "model-a")
        let revoked = await service.isModelConsented(id: "model-a")
        XCTAssertFalse(revoked)
    }

    func testUnregisteredModelIsNotConsented() async {
        let service = ModelManifestService()
        let consented = await service.isModelConsented(id: "unknown")
        XCTAssertFalse(consented)
    }

    func testChecksumRegistrationAndValidation() async {
        let service = ModelManifestService()
        let manifest = ModelManifest(
            id: "model-a",
            checksum: "sha256:abc123",
            signature: "sig:xyz789"
        )

        await service.register(manifest)

        let checksum = await service.checksum(for: "model-a")
        XCTAssertEqual(checksum, "sha256:abc123")

        let signature = await service.signature(for: "model-a")
        XCTAssertEqual(signature, "sig:xyz789")

        let valid = await service.validateChecksum(
            id: "model-a",
            against: "sha256:abc123"
        )
        XCTAssertTrue(valid)

        let invalid = await service.validateChecksum(
            id: "model-a",
            against: "sha256:bad"
        )
        XCTAssertFalse(invalid)
    }

    func testMissingChecksumReturnsNil() async {
        let service = ModelManifestService()
        let checksum = await service.checksum(for: "not-registered")
        XCTAssertNil(checksum)
    }
}
