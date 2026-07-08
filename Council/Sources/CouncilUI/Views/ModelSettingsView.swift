import CouncilCore
import SwiftUI

/// View for displaying the active compute route and consent-gated route changes.
public struct ModelSettingsView: View {
    @Bindable var viewModel: ModelSettingsViewModel

    private let availableRoutes: [ComputeRoute] = [
        .onDeviceApple,
        .applePCC,
        .thirdPartyLocal,
        .thirdPartyCloud,
    ]

    public init(viewModel: ModelSettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Active route") {
                LabeledContent("Path", value: viewModel.computePath)
                LabeledContent("Model", value: viewModel.modelIdentifier)
            }

            Section("Change route") {
                ForEach(availableRoutes, id: \.self) { route in
                    Button {
                        viewModel.requestRouteChange(route)
                    } label: {
                        HStack {
                            Text(ModelSettingsViewModel.label(for: route))
                            if viewModel.activeRoute == route {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(viewModel.activeRoute == route)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Model Settings")
        .alert(
            "Consent required",
            isPresented: $viewModel.consentRequired,
            presenting: viewModel.pendingRoute
        ) { _ in
            Button("Grant consent") {
                viewModel.grantConsent()
            }
            Button("Deny", role: .cancel) {
                viewModel.denyConsent()
            }
        } message: { route in
            Text(
                "Changing the compute route to \(ModelSettingsViewModel.label(for: route)) " +
                "may send data outside this device. Grant explicit consent to proceed."
            )
        }
    }
}
