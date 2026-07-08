import CouncilCore
import SwiftUI

/// Main session view for asking questions and viewing the council's perspective.
public struct SessionView: View {
    @Bindable var viewModel: SessionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(viewModel: SessionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                questionInput
                controls
                StageIndicatorView(currentStage: viewModel.sessionState, reduceMotion: reduceMotion)
                streamingSection
                perspectiveSection
                agentOutputsSection
                errorSection
            }
            .padding()
        }
        .navigationTitle("Council")
        .onAppear {
            viewModel.reduceMotion = reduceMotion
        }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.reduceMotion = newValue
        }
    }

    private var questionInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Question")
                .font(.headline)
            #if os(iOS)
            TextEditor(text: $viewModel.question)
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
            #else
            TextEditor(text: $viewModel.question)
                .frame(minHeight: 60)
                .border(Color.secondary.opacity(0.2))
            #endif
        }
    }

    private var controls: some View {
        HStack {
            Button(viewModel.isRunning ? "Cancel" : "Ask the Council") {
                if viewModel.isRunning {
                    viewModel.cancel()
                } else {
                    viewModel.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !viewModel.isRunning
            )

            Spacer()

            #if os(iOS)
            VoiceInputButton { transcript in
                viewModel.question = transcript
            }
            #endif
        }
    }

    @ViewBuilder
    private var streamingSection: some View {
        if !viewModel.streamingText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.streamingText)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var perspectiveSection: some View {
        if let perspective = viewModel.perspective {
            VStack(alignment: .leading, spacing: 8) {
                Text("Perspective")
                    .font(.headline)
                PerspectiveView(perspective: perspective)
            }
        }
    }

    @ViewBuilder
    private var agentOutputsSection: some View {
        if viewModel.sessionState == .presentation, !uniqueAgentOutputs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent outputs")
                    .font(.headline)
                ForEach(uniqueAgentOutputs, id: \.agentID) { output in
                    AgentCardView(output: output, reduceMotion: reduceMotion)
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var uniqueAgentOutputs: [AgentOutput] {
        var result: [AgentOutput] = []
        var seen = Set<String>()
        for output in viewModel.agentOutputs.reversed() {
            if !seen.contains(output.agentID) {
                seen.insert(output.agentID)
                result.append(output)
            }
        }
        return result.reversed()
    }
}
