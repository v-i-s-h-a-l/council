import CouncilCore
import SwiftUI

/// About view showing constitutional boundaries, privacy summary, and version.
public struct AboutView: View {
    public let version: String

    public init(version: String = "0.1.0") {
        self.version = version
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                constitutionalBoundary
                privacySummary
                versionInfo
            }
            .padding()
        }
        .frame(minWidth: 320, minHeight: 400)
        .navigationTitle("About")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Council")
                .font(.largeTitle)
            Text("A personal, local-first, constitution-governed multi-agent council.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var constitutionalBoundary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Constitutional boundaries")
                .font(.headline)
            Text(loadedConstitution())
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var privacySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy summary")
                .font(.headline)
            Text(
                """
                • Your profile and memories stay on device unless you explicitly consent to another route.
                • The council never mixes users, never phones home, and never monetizes attention.
                • Audit logs are kept locally and chained so tampering is detectable.
                • Voice input uses on-device recognition only; server fallback is blocked.
                """
            )
            .font(.body)
            .foregroundStyle(.secondary)
        }
    }

    private var versionInfo: some View {
        Text("Version \(version)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func loadedConstitution() -> String {
        (try? ConstitutionLoader.loadBundledText()) ?? "Constitution text unavailable."
    }
}
