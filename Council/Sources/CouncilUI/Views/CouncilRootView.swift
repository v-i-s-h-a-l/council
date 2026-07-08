import SwiftUI

/// Root view that uses `NavigationStack` on iOS and `NavigationSplitView` elsewhere.
public struct CouncilRootView: View {
    @Bindable var sessionViewModel: SessionViewModel
    @Bindable var memoryInspectorViewModel: MemoryInspectorViewModel
    @Bindable var modelSettingsViewModel: ModelSettingsViewModel

    public init(
        sessionViewModel: SessionViewModel,
        memoryInspectorViewModel: MemoryInspectorViewModel,
        modelSettingsViewModel: ModelSettingsViewModel
    ) {
        self.sessionViewModel = sessionViewModel
        self.memoryInspectorViewModel = memoryInspectorViewModel
        self.modelSettingsViewModel = modelSettingsViewModel
    }

    public var body: some View {
        #if os(iOS)
        iOSBody
        #else
        splitBody
        #endif
    }

    #if os(iOS)
    @State private var path = NavigationPath()

    private var iOSBody: some View {
        NavigationStack(path: $path) {
            SessionView(viewModel: sessionViewModel)
                .navigationTitle("Council")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                path.append(Route.memory)
                            } label: {
                                Label("Memory", systemImage: "archivebox")
                            }
                            Button {
                                path.append(Route.settings)
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            Button {
                                path.append(Route.about)
                            } label: {
                                Label("About", systemImage: "info.circle")
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                        }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .session:
                        SessionView(viewModel: sessionViewModel)
                    case .memory:
                        MemoryInspectorView(viewModel: memoryInspectorViewModel)
                    case .settings:
                        ModelSettingsView(viewModel: modelSettingsViewModel)
                    case .about:
                        AboutView()
                    }
                }
        }
    }
    #endif

    #if !os(iOS)
    @State private var selectedRoute: Route? = .session

    private var splitBody: some View {
        NavigationSplitView {
            List(selection: $selectedRoute) {
                NavigationLink(value: Route.session) {
                    Label("Session", systemImage: "bubble.left.and.bubble.right")
                }
                NavigationLink(value: Route.memory) {
                    Label("Memory", systemImage: "archivebox")
                }
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
                NavigationLink(value: Route.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Council")
        } detail: {
            switch selectedRoute {
            case .session, .none:
                SessionView(viewModel: sessionViewModel)
            case .memory:
                MemoryInspectorView(viewModel: memoryInspectorViewModel)
            case .settings:
                ModelSettingsView(viewModel: modelSettingsViewModel)
            case .about:
                AboutView()
            }
        }
    }
    #endif
}
