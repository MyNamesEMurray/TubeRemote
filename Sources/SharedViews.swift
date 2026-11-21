import SwiftUI

struct Thumb: View {
    let url: URL
    /// Shown when `url` fails to load.
    var fallback: URL?
    var radius: CGFloat = 6

    var body: some View {
        // The picture sits in an overlay so a wide image fills the frame without spilling out of it.
        Color(.tertiarySystemFill)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else if phase.error != nil, let fallback {
                        Thumb(url: fallback, radius: 0)
                    }
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tertiary).frame(height: 56)
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

struct Pill<Content: View>: View {
    var selected = false
    var onDark = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected || onDark ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? Color.accentColor : onDark ? Color.white.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
            .frame(minHeight: 44)
    }
}

/// A list the viewer scrolls to `follow` and the remote reports the first visible row of through `onTop`, so the
/// two screens can show the same part of it. `onNearEnd` fires when the last rows come into view.
struct FollowScroll<Header: View, Row: View>: View {
    let count: Int
    var follow: Int?
    var onTop: ((Int) -> Void)?
    var onNearEnd: (() -> Void)?
    let header: Header
    let row: (Int) -> Row
    @State private var visible = Set<Int>()
    @State private var reportWork: DispatchWorkItem?

    init(count: Int, follow: Int? = nil, onTop: ((Int) -> Void)? = nil, onNearEnd: (() -> Void)? = nil,
         @ViewBuilder header: () -> Header, @ViewBuilder row: @escaping (Int) -> Row) {
        self.count = count
        self.follow = follow
        self.onTop = onTop
        self.onNearEnd = onNearEnd
        self.header = header()
        self.row = row
    }

    private func report() {
        guard let onTop else { return }
        reportWork?.cancel()
        let w = DispatchWorkItem { onTop(visible.min() ?? 0) }
        reportWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    header.id(-1)
                    ForEach(0..<count, id: \.self) { i in
                        row(i)
                            .id(i)
                            .onAppear {
                                visible.insert(i)
                                report()
                                if i >= count - 3 { onNearEnd?() }
                            }
                            .onDisappear { visible.remove(i); report() }
                    }
                }
                .padding()
            }
            .onChange(of: follow) { f in
                guard let f else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(f == 0 ? -1 : f, anchor: .top) }
            }
        }
    }
}

/// A video's title, facts and description.
struct DescriptionLines: View {
    let info: VideoInfo
    var follow: Int?
    var onTop: ((Int) -> Void)?

    var body: some View {
        let lines = info.lines
        FollowScroll(count: lines.count, follow: follow, onTop: onTop, header: {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.headline)
                Text(info.channel).font(.subheadline).foregroundStyle(.secondary)
                if !info.stats.isEmpty { Text(info.stats).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.bottom, 8)
        }, row: { i in
            Text(lines[i].isEmpty ? " " : lines[i])
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        })
    }
}

struct CommentRow: View {
    let comment: VideoComment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(comment.author).font(.caption.weight(.semibold)).lineLimit(1)
                if let age = comment.age { Text(age).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(comment.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if let likes = comment.likes { Label(likes, systemImage: "hand.thumbsup").labelStyle(.titleAndIcon) }
                if let replies = comment.replies { Label(replies, systemImage: "arrowshape.turn.up.left") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// A video's comments, with what to show while there are none.
struct CommentsList: View {
    let details: VideoDetails?
    var follow: Int?
    var onTop: ((Int) -> Void)?
    var onNearEnd: (() -> Void)?

    var body: some View {
        if let d = details, !d.comments.isEmpty {
            FollowScroll(count: d.comments.count, follow: follow, onTop: onTop, onNearEnd: onNearEnd, header: { EmptyView() }, row: { i in
                VStack(alignment: .leading, spacing: 0) {
                    CommentRow(comment: d.comments[i])
                    Divider()
                }
            })
        } else if details?.commentsStatus == "none" {
            EmptyState(symbol: "bubble.left", title: "No comments", message: "Comments are off for this video, or none were found.")
        } else if details?.commentsStatus == "error" {
            EmptyState(symbol: "exclamationmark.bubble", title: "Couldn't load comments", message: "YouTube did not answer in a form this app reads.")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Queue with tap-to-play, swipe-to-delete, drag reorder (in Reorder mode) and clear.
struct QueueList: View {
    let items: [VideoItem]
    let onPlay: (VideoItem) -> Void
    let onRemove: (VideoItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onClear: () -> Void
    /// What autoplay will play after the queue, with a tap to queue it and a swipe to ask for another.
    var autoplayNext: VideoItem?
    var onAddNext: (VideoItem) -> Void = { _ in }
    var onAnother: () -> Void = {}
    @State private var editMode: EditMode = .inactive
    @State private var confirmClear = false

    var body: some View {
        if items.isEmpty && autoplayNext == nil {
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
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .frame(minHeight: 44)
                        .padding(.leading, 8)
                }
                .padding(.horizontal)
                .confirmationDialog("Clear the queue?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear Queue", role: .destructive) {
                        Haptics.warning()
                        onClear()
                    }
                }
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
                    if let n = autoplayNext {
                        Section {
                            Button {
                                Haptics.tap()
                                onAddNext(n)
                            } label: { VideoRow(item: n).opacity(0.7) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Adds this video to the queue")
                                .swipeActions {
                                    Button { Haptics.tap(); onAnother() } label: {
                                        Label("Another", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .tint(.accentColor)
                                }
                        } header: {
                            Label("Autoplay", systemImage: "infinity")
                        }
                    }
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
    @State private var confirmClear = false

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "clock", title: "No history yet", message: "Videos you play will show up here.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Recently Played").font(.headline)
                    Spacer()
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .frame(minHeight: 44)
                }
                .padding(.horizontal)
                .confirmationDialog("Clear history?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear History", role: .destructive) {
                        Haptics.warning()
                        onClear()
                    }
                }
                List(items) { item in
                    Menu {
                        Button { Haptics.tap(); onReplay(item) } label: { Label("Replay now", systemImage: "play.fill") }
                        Button { Haptics.tap(); onRequeue(item) } label: { Label("Add to queue", systemImage: "text.append") }
                    } label: {
                        VideoRow(item: item)
                    } primaryAction: {
                        // A tap must not cut off what is playing; Replay now stays in the menu.
                        Haptics.success()
                        onRequeue(item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Adds to the queue. Actions available for more options")
                }
                .listStyle(.plain)
            }
        }
    }
}
