import CouncilCore
import CouncilMemory
import SwiftUI

/// View for inspecting and managing memory episodes and temporal facts.
public struct MemoryInspectorView: View {
    @Bindable var viewModel: MemoryInspectorViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editingEpisode: EpisodicGist?

    public init(viewModel: MemoryInspectorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            Section("Episodes") {
                ForEach(viewModel.episodes) { episode in
                    EpisodeRow(
                        episode: episode,
                        viewModel: viewModel,
                        onEdit: { editingEpisode = episode }
                    )
                }
            }
            Section("Facts") {
                ForEach(viewModel.facts) { fact in
                    FactRow(fact: fact, viewModel: viewModel)
                }
            }
        }
        .navigationTitle("Memory")
        .task {
            await viewModel.load()
        }
        .sheet(item: $editingEpisode) { episode in
            EpisodeEditor(episode: episode) { updated in
                Task {
                    await viewModel.updateEpisode(updated)
                }
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: EpisodicGist
    @Bindable var viewModel: MemoryInspectorViewModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(episode.question)
                .font(.headline)
            Text(episode.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)

                Button {
                    Task {
                        await viewModel.lockEpisode(id: episode.id, isLocked: !episode.isLocked)
                    }
                } label: {
                    Label(
                        episode.isLocked ? "Unlock" : "Lock",
                        systemImage: episode.isLocked ? "lock.open" : "lock"
                    )
                }
                .buttonStyle(.borderless)

                Button {
                    Task {
                        await viewModel.deleteEpisode(id: episode.id)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
            .font(.caption)
        }
    }
}

private struct FactRow: View {
    let fact: TemporalFact
    @Bindable var viewModel: MemoryInspectorViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(fact.subject) \(fact.predicate) \(fact.object)")
                    .font(.body)
                Text(fact.accessScope.map(\.rawValue).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await viewModel.deleteFact(id: fact.id)
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .tint(.red)
        }
    }
}

private struct EpisodeEditor: View {
    @State var episode: EpisodicGist
    let onSave: (EpisodicGist) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Question", text: $episode.question)
                TextEditor(text: perspectiveBinding(\.summary))
                    .frame(minHeight: 80)
            }
            .navigationTitle("Edit Episode")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(episode)
                        dismiss()
                    }
                }
            }
        }
    }

    private func perspectiveBinding(_ keyPath: WritableKeyPath<Perspective, String>) -> Binding<String> {
        Binding(
            get: { episode.perspective[keyPath: keyPath] },
            set: { episode.perspective[keyPath: keyPath] = $0 }
        )
    }
}
