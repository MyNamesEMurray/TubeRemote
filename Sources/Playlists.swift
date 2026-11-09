import SwiftUI

struct SavedQueue: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var items: [VideoItem]
    var created = Date()
}

final class PlaylistStore: ObservableObject {
    @Published var queues: [SavedQueue] {
        didSet { Store.write("playlists.json", try? JSONEncoder().encode(queues)) }
    }

    init() {
        queues = Store.read("playlists.json").flatMap { try? JSONDecoder().decode([SavedQueue].self, from: $0) } ?? []
    }

    func add(name: String, items: [VideoItem]) {
        queues.insert(SavedQueue(name: name, items: items), at: 0)
    }
}

struct PlaylistBar: View {
    private enum Sheet: String, Identifiable {
        case save, saved, paywall
        var id: String { rawValue }
    }

    @ObservedObject var client: RemoteClient
    @ObservedObject var store: PlaylistStore
    @EnvironmentObject var pro: ProStore
    @State private var sheet: Sheet?

    private var queue: [VideoItem] { client.state?.queue ?? [] }

    private func open(_ s: Sheet) {
        Haptics.tap()
        sheet = pro.isPro ? s : .paywall
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { open(.save) } label: { Label("Save Queue", systemImage: "square.and.arrow.down") }
                .disabled(queue.isEmpty)
            Button { open(.saved) } label: { Label("Saved", systemImage: "bookmark") }
            if !pro.isPro { GatedBadge() }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .padding(.horizontal)
        .padding(.top, 8)
        .sheet(item: $sheet) { s in
            switch s {
            case .save:
                SaveQueueSheet(count: queue.count) { store.add(name: $0, items: queue) }
            case .saved:
                SavedQueuesSheet(store: store, client: client)
            case .paywall:
                PaywallView()
            }
        }
    }
}

private struct SaveQueueSheet: View {
    let count: Int
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    Text("Saves the \(count) videos in the queue.")
                }
            }
            .navigationTitle("Save Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(trimmed)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SavedQueuesSheet: View {
    @ObservedObject var store: PlaylistStore
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var picked: SavedQueue?

    private func play(_ q: SavedQueue) {
        guard let first = q.items.first else { return }
        client.send(.clearQueue)
        client.send(.play(first))
        q.items.dropFirst().forEach { client.send(.enqueue($0)) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.queues.isEmpty {
                    EmptyState(symbol: "bookmark", title: "No saved queues", message: "Save the current queue to replay it later.")
                } else {
                    List {
                        ForEach(store.queues) { q in
                            Button { picked = q } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(q.name).font(.body).foregroundStyle(.primary)
                                    Text("\(q.items.count) videos · \(q.created.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { store.queues.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Saved Queues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(picked?.name ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                                titleVisibility: .visible, presenting: picked) { q in
                Button("Play now") { play(q); dismiss() }
                Button("Add to queue") { q.items.forEach { client.send(.enqueue($0)) }; dismiss() }
            }
        }
    }
}
