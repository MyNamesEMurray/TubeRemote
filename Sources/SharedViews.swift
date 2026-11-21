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

struct SkipIcon: View {
    let seconds: Int
    let forward: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: forward ? "goforward" : "gobackward")
            .font(.system(size: size))
            .overlay(
                Text("\(seconds)")
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .offset(y: size * 0.04)
            )
    }
}

struct HoldToScan: ViewModifier {
    let direction: Int
    let send: (Int) -> Void
    @GestureState private var holding = false
    @State private var timer: Timer?
    private static var endedAt = Date.distantPast

    static var justScanned: Bool { Date().timeIntervalSince(endedAt) < 0.4 }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
            )
            .onChange(of: holding) { on in
                timer?.invalidate()
                timer = nil
                if on {
                    Haptics.pop()
                    send(direction)
                    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in send(direction) }
                } else {
                    Self.endedAt = Date()
                    send(0)
                }
            }
    }
}

struct ScrubBar: View {
    let value: Double
    let maxValue: Double
    let onScrub: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    var onActive: (Bool) -> Void = { _ in }
    @State private var active = false
    @State private var current = 0.0
    @State private var startValue = 0.0
    @State private var lastX = 0.0
    @State private var startY = 0.0
    @State private var tier = 0
    @GestureState private var touching = false

    private static let tiers: [(label: String, factor: Double)] = [
        ("", 1), ("Half speed", 0.5), ("Quarter speed", 0.25), ("Fine", 0.1), ("Release to cancel", 0),
    ]
    private static let cancelTier = 4

    private func finish() {
        guard active else { return }
        let cancelled = tier == Self.cancelTier
        active = false
        tier = 0
        onActive(false)
        if cancelled { onCancel() } else { onEnd() }
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let top = max(maxValue, 1)
            let shown = active ? (tier == Self.cancelTier ? startValue : current) : value
            let frac = min(max(shown / top, 0), 1)
            let knob: CGFloat = active ? 24 : 16
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: w * frac, height: 4)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: w * frac - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if active, tier > 0 {
                    Text(Self.tiers[tier].label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tier == Self.cancelTier ? Color.red : Color.black.opacity(0.7), in: Capsule())
                        .offset(y: -22)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { v in
                        let x = min(max(v.location.x, 0), w)
                        if !active {
                            active = true
                            onActive(true)
                            startValue = value
                            current = abs(x - w * min(max(value / top, 0), 1)) > 28 ? x / w * top : value
                            lastX = x
                            startY = v.location.y
                            tier = 0
                        } else {
                            let dy = abs(v.location.y - startY)
                            let t = dy < 50 ? 0 : dy < 110 ? 1 : dy < 180 ? 2 : dy < 260 ? 3 : Self.cancelTier
                            if t != tier {
                                let entering = t == Self.cancelTier
                                tier = t
                                if entering { Haptics.pop() } else { Haptics.tap() }
                            }
                            current = min(max(current + (x - lastX) * (top / w) * Self.tiers[tier].factor, 0), top)
                            lastX = x
                        }
                        if tier != Self.cancelTier { onScrub(current) }
                    }
                    .onEnded { _ in finish() }
            )
            .onChange(of: touching) { if !$0 { finish() } }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(clock(value)) of \(clock(maxValue))")
        .accessibilityAdjustableAction { direction in
            let step = max(maxValue / 50, 5)
            onScrub(min(max(value + (direction == .increment ? step : -step), 0), maxValue))
            onEnd()
        }
    }
}

struct LivePill: View {
    let atHead: Bool
    let action: () -> Void
    var onDark = false

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(atHead ? Color.white : Color.red).frame(width: 7, height: 7)
                Text(atHead ? "LIVE" : "Go live").font(.caption.bold())
            }
            .foregroundStyle(atHead || onDark ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(atHead ? Color.red : onDark ? Color.white.opacity(0.18) : Color(.secondarySystemFill), in: Capsule())
        }
        .disabled(atHead)
        .accessibilityLabel(atHead ? "Live" : "Go to the live edge")
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
