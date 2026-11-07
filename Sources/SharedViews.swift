import SwiftUI

struct Thumb: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.3)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct VideoRow: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            Thumb(url: item.thumbnailURL).frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                HStack {
                    Text(item.channel).lineLimit(1)
                    if let d = item.duration { Text("· " + clock(d)) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Queue with tap-to-play, swipe-to-delete, drag reorder (in Reorder mode) and clear.
struct QueueList: View {
    let items: [VideoItem]
    let onPlay: (VideoItem) -> Void
    let onRemove: (VideoItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onClear: () -> Void
    @State private var editMode: EditMode = .inactive

    var body: some View {
        if items.isEmpty {
            Text("Queue is empty").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                    Spacer()
                    Button("Clear", role: .destructive, action: onClear)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                List {
                    ForEach(items) { item in
                        Button { onPlay(item) } label: { VideoRow(item: item) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { offsets in offsets.map { items[$0] }.forEach(onRemove) }
                    .onMove(perform: onMove)
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
            }
        }
    }
}

struct HistoryList: View {
    let items: [VideoItem]
    let onReplay: (VideoItem) -> Void
    let onRequeue: (VideoItem) -> Void
    let onClear: () -> Void

    var body: some View {
        if items.isEmpty {
            Text("No history yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Clear", role: .destructive, action: onClear)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                List(items) { item in
                    Menu {
                        Button { onReplay(item) } label: { Label("Replay now", systemImage: "play.fill") }
                        Button { onRequeue(item) } label: { Label("Add to queue", systemImage: "text.append") }
                    } label: {
                        VideoRow(item: item)
                    } primaryAction: {
                        onReplay(item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }
}
