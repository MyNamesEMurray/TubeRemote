import SwiftUI

struct Thumb: View {
    let url: URL
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

struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let material: Material

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

struct PanelBackground: ViewModifier {
    let floating: Bool

    func body(content: Content) -> some View {
        if floating {
            content.glassBackground(RoundedRectangle(cornerRadius: 22, style: .continuous), .regularMaterial)
        } else {
            content.background(.regularMaterial)
        }
    }
}

extension View {
    func glassBackground<S: Shape>(_ shape: S, _ material: Material) -> some View {
        modifier(GlassBackground(shape: shape, material: material))
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
                    .offset(y: size * 0.065)
            )
    }
}

struct HoldToScan: ViewModifier {
    let direction: Int
    let send: (Int) -> Void
    let end: (Double) -> Void
    @GestureState private var holding = false
    @State private var timer: Timer?
    @State private var pressedAt = Date()
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
                    pressedAt = Date()
                    send(direction)
                    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in send(direction) }
                } else {
                    Self.endedAt = Date()
                    end(Date().timeIntervalSince(pressedAt))
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
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
    var preview: (Double) -> UIImage? = { _ in nil }
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
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.75))
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
            .overlay(alignment: .topLeading) {
                if active, tier > 0, tier != Self.cancelTier {
                    let tw = min(72, w / 5 - 2)
                    let th = tw * 9 / 16
                    let step = tw * top / w * Self.tiers[tier].factor
                    VStack(spacing: 3) {
                        HStack(spacing: 2) {
                            ForEach(-2...2, id: \.self) { i in
                                let t = shown + Double(i) * step
                                Group {
                                    if t >= 0, t <= top, let image = preview(t) {
                                        Image(uiImage: image).resizable()
                                    } else {
                                        Color.black.opacity(0.5)
                                    }
                                }
                                .frame(width: tw, height: th)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(i == 0 ? 0.95 : 0.3), lineWidth: i == 0 ? 2 : 1))
                                .opacity(i == 0 ? 1 : 0.65)
                            }
                        }
                        Text(clock(shown))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7), in: Capsule())
                    }
                    .frame(width: (tw + 2) * 5)
                    .offset(x: min(max(w * frac - (tw + 2) * 2.5, 0), max(w - (tw + 2) * 5, 0)), y: -th - 56)
                    .allowsHitTesting(false)
                } else if active, tier != Self.cancelTier, let image = preview(shown) {
                    VStack(spacing: 3) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: 160, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.6), lineWidth: 1))
                        Text(clock(shown))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7), in: Capsule())
                    }
                    .offset(x: min(max(w * frac - 80, 0), max(w - 160, 0)), y: -130)
                    .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { v in
                        let x = active ? v.location.x : min(max(v.location.x, 0), w)
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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

struct FollowScroll<Header: View, Row: View>: View {
    let count: Int
    var follow: Int?
    var onTop: ((Int) -> Void)?
    var onNearEnd: (() -> Void)?
    let header: Header
    let row: (Int) -> Row
    private final class Seen {
        var visible = Set<Int>()
        var work: DispatchWorkItem?
    }
    @State private var seen = Seen()

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
        seen.work?.cancel()
        let box = seen
        let w = DispatchWorkItem { onTop(box.visible.min() ?? 0) }
        seen.work = w
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
                                seen.visible.insert(i)
                                report()
                                if i >= count - 3 { onNearEnd?() }
                            }
                            .onDisappear { seen.visible.remove(i); report() }
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

private enum LinkTools {
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let time = try? NSRegularExpression(pattern: "(?<![\\d:])(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})(?![\\d:])")
}

func linkified(_ line: String) -> AttributedString {
    var out = AttributedString(line)
    let whole = NSRange(location: 0, length: (line as NSString).length)
    if let detector = LinkTools.detector {
        for m in detector.matches(in: line, range: whole) {
            if let url = m.url, let r = Range(m.range, in: out) { out[r].link = url }
        }
    }
    if let re = LinkTools.time {
        for m in re.matches(in: line, range: whole) {
            func part(_ i: Int) -> Int {
                let r = m.range(at: i)
                return r.location == NSNotFound ? 0 : Int((line as NSString).substring(with: r)) ?? 0
            }
            let seconds = part(1) * 3600 + part(2) * 60 + part(3)
            if let r = Range(m.range, in: out), out[r].link == nil { out[r].link = URL(string: "tubeseek://\(seconds)") }
        }
    }
    return out
}

struct DescriptionLines: View {
    let info: VideoInfo
    var follow: Int?
    var position: Int?
    var onTop: ((Int) -> Void)?
    var onPosition: ((Int) -> Void)?
    var onSeek: ((Double) -> Void)?

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.title).font(.headline)
            Text(info.channel).font(.subheadline).foregroundStyle(.secondary)
            if !info.stats.isEmpty { Text(info.stats).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.bottom, 8)
    }

    private func line(_ text: String) -> some View {
        Text(text.isEmpty ? AttributedString(" ") : linkified(text))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard let onSeek else { return .discarded }
                if url.scheme == "tubeseek", let s = Double(url.host ?? "") {
                    onSeek(s)
                    return .handled
                }
                return .systemAction
            })
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            ProportionalScroll(position: position, onPosition: onPosition) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    ForEach(Array(info.lines.enumerated()), id: \.offset) { _, text in line(text) }
                }
            }
        } else {
            let lines = info.lines
            FollowScroll(count: lines.count, follow: follow, onTop: onTop, header: { header }, row: { i in line(lines[i]) })
        }
    }
}

/// Both screens scroll by how far down the text is, as a fraction, because they wrap it at different widths. A row number
/// would put the phone halfway through a long paragraph while the iPad showed its first line.
@available(iOS 18.0, *)
struct ProportionalScroll<Content: View>: View {
    var position: Int?
    var onPosition: ((Int) -> Void)?
    @ViewBuilder let content: Content
    private final class Throttle {
        var last = Date.distantPast
        var work: DispatchWorkItem?
    }
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var maxOffset: CGFloat = 0
    @State private var throttle = Throttle()

    private func report(_ p: Int) {
        guard let onPosition else { return }
        throttle.work?.cancel()
        let box = throttle
        let wait = max(0, 0.1 - Date().timeIntervalSince(box.last))
        let w = DispatchWorkItem {
            box.last = Date()
            onPosition(p)
        }
        box.work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }

    private func follow(_ p: Int?) {
        guard let p, maxOffset > 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) { scroll.scrollTo(y: CGFloat(p) / 1000 * maxOffset) }
    }

    var body: some View {
        ScrollView { content.padding() }
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self, of: { max($0.contentSize.height - $0.containerSize.height, 0) },
                                    action: { _, v in maxOffset = v })
            .onScrollGeometryChange(for: Int.self, of: { g in
                let range = max(g.contentSize.height - g.containerSize.height, 1)
                return Int((min(max(g.contentOffset.y, 0) / range, 1) * 1000).rounded())
            }, action: { _, p in report(p) })
            .onChange(of: position) { _, p in follow(p) }
            .onChange(of: maxOffset) { _, _ in follow(position) }
    }
}

struct CommentRow: View {
    let comment: VideoComment
    var expanded = false
    var isReply = false
    var onToggle: (() -> Void)?

    private var hasReplies: Bool { !isReply && comment.replies != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(comment.author).font(.caption.weight(.semibold)).lineLimit(1)
                if let age = comment.age { Text(age).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(comment.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if let likes = comment.likes { Label(likes, systemImage: "hand.thumbsup").labelStyle(.titleAndIcon) }
                if hasReplies, let n = comment.replies {
                    Label("\(n) \(n == "1" ? "reply" : "replies")", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if expanded && hasReplies {
                if let list = comment.replyList {
                    if list.isEmpty {
                        Text("Couldn't load the replies").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                    }
                    ForEach(list) { r in
                        CommentRow(comment: r, isReply: true)
                            .padding(.leading, 14)
                            .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
                    }
                    if let total = Int(comment.replies ?? ""), total > list.count, !list.isEmpty {
                        Text("Showing the first \(list.count) replies").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                    }
                } else {
                    ProgressView().padding(.leading, 14).padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, expanded && !isReply ? 8 : 0)
        .background(expanded && !isReply ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !isReply { onToggle?() } }
    }
}

struct CommentsList: View {
    let details: VideoDetails?
    var follow: Int?
    var onTop: ((Int) -> Void)?
    var onNearEnd: (() -> Void)?
    var solo = false
    var onToggle: ((String) -> Void)?

    var body: some View {
        if solo, let d = details, let id = d.expanded.first, let c = d.comments.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CommentRow(comment: c, expanded: true, onToggle: { onToggle?(c.id) })
                    Text("Tap the comment to show them all again").font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
        } else if let d = details, !d.comments.isEmpty {
            FollowScroll(count: d.comments.count, follow: follow, onTop: onTop, onNearEnd: onNearEnd, header: { EmptyView() }, row: { i in
                VStack(alignment: .leading, spacing: 0) {
                    CommentRow(comment: d.comments[i], expanded: d.expanded.contains(d.comments[i].id),
                               onToggle: { onToggle?(d.comments[i].id) })
                    Divider()
                }
            })
        } else if details?.commentsStatus == "none" {
            EmptyState(symbol: "bubble.left", title: "No comments", message: "Comments are off for this video, or none were found.")
        } else if details?.commentsStatus == "error" {
            EmptyState(symbol: "exclamationmark.bubble", title: "Couldn't load comments", message: "YouTube didn't answer in a form this app can read.")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct QueueList: View {
    let items: [VideoItem]
    let onPlay: (VideoItem) -> Void
    let onRemove: (VideoItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onClear: () -> Void
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
                    Text("Queue").font(.headline)
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
                            Label("Autoplay", systemImage: "infinity").padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListHeaderHeight, 0)
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
                    Text("History").font(.headline)
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
                        Button { Haptics.success(); onRequeue(item) } label: { Label("Add to queue", systemImage: "text.append") }
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
