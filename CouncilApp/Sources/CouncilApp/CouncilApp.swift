import CouncilUI
import SwiftUI

@main
struct CouncilApp: App {
    @State private var root: CompositionRoot?

    var body: some Scene {
        WindowGroup {
            Group {
                if let root {
                    CouncilRootView(
                        sessionViewModel: root.sessionViewModel,
                        memoryInspectorViewModel: root.memoryInspectorViewModel,
                        modelSettingsViewModel: root.modelSettingsViewModel
                    )
                } else {
                    ProgressView("Initializing Council…")
                }
            }
            .task {
                root = try? await CompositionRoot()
            }
        }
    }
}
