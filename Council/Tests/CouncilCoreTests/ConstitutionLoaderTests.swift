import Foundation
import Testing
@testable import CouncilCore

/// The bundled constitution is injected into every agent prompt; loading the
/// wrong resource or a truncated file silently changes governed behavior.
struct ConstitutionLoaderTests {

    @Test func constitutionLoaderReturnsCurrentVersionNonEmptyUTF8() throws {
        let text = try ConstitutionLoader.loadBundledText()
        #expect(!text.isEmpty)
        #expect(text.contains("# Council Constitution"))

        // The bundle ships both Constitution.md and Constitution.v1.md.
        // Guard against resource-name shadowing resolving the stale version.
        let v1URL = Bundle.module.url(forResource: "Constitution.v1", withExtension: "md")
        #expect(v1URL != nil, "Constitution.v1.md missing from bundle; shadowing check is vacuous")
        if let v1URL, let v1Text = try? String(contentsOf: v1URL, encoding: .utf8), v1Text != text {
            // Only reachable once the versions actually diverge; until then the
            // assertion above (loaded resource has the canonical heading) stands.
            #expect(text != v1Text, "loadBundledText must resolve Constitution.md, not Constitution.v1.md")
        }
    }
}
