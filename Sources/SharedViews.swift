import SwiftUI

struct Thumb: View {
    let url: URL
    var radius: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Color(.tertiarySystemFill)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct GatedBadge: View {
    var body: some View {
        Label("Pro", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct VideoRow: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            Thumb(url: item.thumbnailURL, radius: 8).frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(item.channel).lineLimit(1)
                    if let d = item.duration { Text("· " + clock(d)).monospacedDigit() }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
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
            EmptyState(symbol: "list.bullet", title: "Queue is empty", message: "Videos you add will show up here.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Up Next").font(.headline)
                    Spacer()
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                    .frame(minHeight: 44)
                    Button("Clear", role: .destructive) {
                        Haptics.warning()
                        onClear()
                    }
                    .frame(minHeight: 44)
                    .padding(.leading, 8)
                }
                .padding(.horizontal)
                List {
                    ForEach(items) { item in
                        Button {
                            Haptics.tap()
                            onPlay(item)
                        } label: { VideoRow(item: item) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays this video now")
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
            EmptyState(symbol: "clock", title: "No history yet", message: "Videos you play will show up here.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Recently Played").font(.headline)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        Haptics.warning()
                        onClear()
                    }
                    .frame(minHeight: 44)
                }
                .padding(.horizontal)
                List(items) { item in
                    Menu {
                        Button { Haptics.tap(); onReplay(item) } label: { Label("Replay now", systemImage: "play.fill") }
                        Button { Haptics.tap(); onRequeue(item) } label: { Label("Add to queue", systemImage: "text.append") }
                    } label: {
                        VideoRow(item: item)
                    } primaryAction: {
                        Haptics.tap()
                        onReplay(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays again. Actions available for more options")
                }
                .listStyle(.plain)
            }
        }
    }
}
