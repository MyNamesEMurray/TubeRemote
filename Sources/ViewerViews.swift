import SwiftUI
import MediaPlayer

struct ViewerView: View {
    @EnvironmentObject var viewer: ViewerController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var showSettings: Bool
    @State private var showQueue = false
    @State private var showBrowse = false
    @State private var showPair = false
    @State private var showControls = false
    @State private var hideWork: DispatchWorkItem?
    @State private var showMenu = false
    @State private var menuWork: DispatchWorkItem?
    @State private var nowPlaying: VideoItem?
    @State private var nowWork: DispatchWorkItem?

    private var sideWidth: CGFloat {
        hSize == .regular && (viewer.richView || showQueue) ? (viewer.richView ? 380 : 340) : 0
    }

    @ViewBuilder private var sidePanel: some View {
        if viewer.richView { RichPanel() } else { QueueSidebar(onClose: closePanel) }
    }

    private func closePanel() {
        if viewer.richView { viewer.handle(.setRichView(false), from: nil) } else { showQueue = false }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let panel: CGFloat = viewer.richView ? 380 : 340
                let open = hSize == .regular && (viewer.richView || showQueue)
                ZStack(alignment: .trailing) {
                    Hosted(view: viewer.webView)
                        .scaleEffect(open ? max(geo.size.width - panel, 1) / max(geo.size.width, 1) : 1, anchor: .leading)
                    if open {
                        SwipeAway(onClose: closePanel) { sidePanel }
                            .frame(width: panel)
                            .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.15)).frame(width: 0.5) }
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            if viewer.current == nil { IdleView { showPair = true } }
            // Off-screen volume slider; the only way to set system volume from an app.
            Hosted(view: viewer.volumeView).frame(width: 10, height: 10).clipped().opacity(0.01).allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .trailing) {
            if (showQueue || viewer.richView) && hSize == .compact {
                SwipeAway(onClose: closePanel) { sidePanel }
                    .frame(width: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 16)
                    .padding(.top, 64).padding(.trailing, 8).padding(.bottom, 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let n = nowPlaying, !showControls {
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.title).font(.headline).lineLimit(2)
                    Text(n.channel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let t = viewer.toast {
                Text(t)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showControls, viewer.current != nil {
                ViewerControls(touched: { keepControls() }, menuOpened: { keepControls(for: 12) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Shown with the overlay, and while the menu or queue is open. Hidden, it also lets taps through.
            let visible = showMenu || showControls || showQueue || viewer.current == nil
            menu
                .padding(.trailing, sideWidth)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sideWidth)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
        }
        .overlay(alignment: .topLeading) {
            if viewer.needsUnmute {
                Button {
                    Haptics.tap()
                    viewer.unmuteVideo()
                } label: {
                    Label("Tap to unmute", systemImage: "speaker.slash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        // The page reports taps on the video; nothing native sits on top of it to catch them.
        .onReceive(viewer.tapped) { _ in
            closeMenu()
            if showControls { hideWork?.cancel(); showControls = false } else { keepControls() }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
        .animation(.easeInOut(duration: 0.4), value: showMenu)
        .animation(.easeInOut(duration: 0.3), value: viewer.needsUnmute)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewer.toast)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewer.richView)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nowPlaying)
        .onChange(of: viewer.current?.videoID) { _ in announce() }
        .sheet(isPresented: $showBrowse) { LocalBrowse() }
        .sheet(isPresented: $showPair) { PairSheet() }
        .pairingPrompt()
        .preferredColorScheme(.dark)
    }

    /// Shows the controls and hides them again after four quiet seconds, or `seconds`.
    private func keepControls(for seconds: Double = 4) {
        hideWork?.cancel()
        showControls = true
        let w = DispatchWorkItem { showControls = false }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func announce() {
        nowWork?.cancel()
        guard let c = viewer.current else { nowPlaying = nil; return }
        nowPlaying = c
        let w = DispatchWorkItem { nowPlaying = nil }
        nowWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func closeMenu() {
        menuWork?.cancel()
        showMenu = false
    }

    /// Opens or closes the menu. Unlike a system menu it fades away by itself after six seconds.
    private func toggleMenu() {
        Haptics.tap()
        guard !showMenu else { return closeMenu() }
        showMenu = true
        let w = DispatchWorkItem { showMenu = false }
        menuWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    private func menuRow(_ title: String, _ symbol: String, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            closeMenu()
            action()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: symbol)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var menu: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: toggleMenu) {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Menu")
            if showMenu {
                VStack(alignment: .leading, spacing: 0) {
                    menuRow("Browse YouTube", "safari") { showBrowse = true }
                    Divider()
                    menuRow("Devices", "link") { showPair = true }
                    Divider()
                    menuRow(showQueue ? "Hide queue" : "Show queue", "list.bullet") { showQueue.toggle() }
                    Divider()
                    menuRow("Settings", "gearshape") { showSettings = true }
                    Divider()
                    menuRow("End session", "stop.circle", tint: .red) {
                        showQueue = false
                        viewer.endSession()
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 240)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
            }
        }
        .padding(12)
    }
}

/// Playback controls on the viewer itself, shown by tapping the video.
struct ViewerControls: View {
    @EnvironmentObject var viewer: ViewerController
    @EnvironmentObject var settings: AppSettings
    @StateObject private var storyboard = Storyboard()
    /// Called on every interaction so the controls stay up while in use.
    let touched: () -> Void
    /// A menu can be open longer than the usual quiet time, and opening one calls no button action.
    let menuOpened: () -> Void
    @State private var scrub: Double?

    private func loadStoryboard() {
        if let d = viewer.details, d.videoID == viewer.current?.videoID {
            storyboard.load(spec: d.storyboard, videoID: d.videoID, duration: viewer.duration)
        } else {
            storyboard.reset()
        }
    }

    private func skipButton(forward: Bool) -> some View {
        let n = settings.skipSeconds
        return Button {
            guard !HoldToScan.justScanned else { return }
            Haptics.tap()
            touched()
            viewer.handle(.skip(forward ? Double(n) : Double(-n)), from: nil)
        } label: {
            SkipIcon(seconds: n, forward: forward, size: 26).frame(width: 56, height: 56).contentShape(Rectangle())
        }
        .accessibilityLabel(forward ? "Forward \(n) seconds" : "Back \(n) seconds")
        .modifier(HoldToScan(direction: forward ? 1 : -1) { touched(); viewer.handle(.scan($0), from: nil) })
    }

    private func button(_ symbol: String, _ label: String, _ cmd: Command, size: CGFloat = 26) -> some View {
        Button {
            Haptics.tap()
            touched()
            viewer.handle(cmd, from: nil)
        } label: {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 56, height: 56).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private func option(_ text: String, _ symbol: String, selected: Bool = false) -> some View {
        Pill(selected: selected, onDark: true) { Label(text, systemImage: symbol) }
    }

    private func check(_ text: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            touched()
            action()
        } label: {
            if on { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
    }

    private var speedPill: some View {
        Menu {
            ForEach(playbackSpeeds, id: \.self) { r in
                check(rateLabel(r), r == viewer.speed) { viewer.handle(.setSpeed(r), from: nil) }
            }
        } label: {
            option(rateLabel(viewer.speed), "speedometer")
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Playback speed, \(rateLabel(viewer.speed))")
    }

    private var captionsPill: some View {
        Button {
            Haptics.tap()
            touched()
            // While searching, a tap cancels the request.
            viewer.handle(.setCaptions(!viewer.captions && viewer.captionsStatus == nil), from: nil)
        } label: {
            switch viewer.captionsStatus {
            case "none": option("No captions", "captions.bubble").opacity(0.5)
            case "searching": option("Finding captions…", "captions.bubble")
            default: option("Captions", viewer.captions ? "captions.bubble.fill" : "captions.bubble", selected: viewer.captions)
            }
        }
        .disabled(viewer.captionsStatus == "none")
        .accessibilityLabel(viewer.captionsStatus == "none" ? "This video has no captions"
                            : viewer.captions ? "Turn captions off" : "Turn captions on")
    }

    private var sleepPill: some View {
        SleepTimerMenu(endsAt: viewer.sleepEndsAt, onDark: true, unlocked: viewer.sessionPro) {
            touched()
            viewer.handle(.setSleepTimer($0), from: nil)
        }
        .equatable()
    }

    private var autoplayPill: some View {
        AutoplayButton(on: viewer.autoplay, onDark: true, unlocked: viewer.sessionPro) {
            touched()
            viewer.handle(.setAutoplay($0), from: nil)
        }
    }

    @ViewBuilder private var qualityPill: some View {
        if viewer.qualities.count > 1 {
            Menu {
                check("Auto", viewer.autoQuality) { viewer.handle(.setQuality("auto"), from: nil) }
                ForEach(viewer.qualities, id: \.self) { q in
                    check(qualityLabel(q), !viewer.autoQuality && q == viewer.quality) {
                        viewer.handle(.setQuality(q), from: nil)
                    }
                }
            } label: {
                // In automatic mode say so, with the quality YouTube picked.
                option(viewer.autoQuality ? "Auto \(qualityLabel(viewer.quality))" : qualityLabel(viewer.quality), "tv")
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Quality, \(qualityLabel(viewer.quality))")
        }
    }

    /// Captions, quality and the rest, the same options the remote has. On one row if they fit, else on two.
    private var options: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { speedPill; captionsPill; sleepPill; autoplayPill; qualityPill }
            VStack(spacing: 0) {
                HStack(spacing: 12) { speedPill; captionsPill; sleepPill }
                HStack(spacing: 12) { autoplayPill; qualityPill }
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in menuOpened() })
    }

    private func commitSeek() {
        guard let v = scrub else { return }
        scrub = nil
        viewer.handle(.seek(v), from: nil)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let c = viewer.current {
                Text(c.title).font(.headline).lineLimit(1)
                if viewer.autoplay, viewer.queue.isEmpty, let n = viewer.autoplayNext {
                    Label("Up next: \(n.title)", systemImage: "infinity")
                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            // Position is read on a timer here instead of being published, so only this row redraws.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let pos = scrub ?? viewer.position
                HStack(spacing: 12) {
                    Text(clock(pos))
                    ScrubBar(
                        value: scrub ?? (viewer.live && viewer.atLiveHead ? viewer.duration : viewer.position),
                        maxValue: viewer.duration,
                        onScrub: { scrub = $0; touched() },
                        onEnd: commitSeek,
                        onCancel: { scrub = nil },
                        preview: { storyboard.frame(at: $0) })
                    if viewer.live {
                        LivePill(atHead: viewer.atLiveHead, action: { touched(); viewer.handle(.goLive, from: nil) }, onDark: true)
                    } else {
                        Text("-" + clock(max(viewer.duration - pos, 0)))
                    }
                }
                .font(.caption.monospacedDigit())
            }
            HStack(spacing: 16) {
                button("backward.end.fill", "Previous", .previous)
                skipButton(forward: false)
                button(viewer.isPlaying ? "pause.fill" : "play.fill", viewer.isPlaying ? "Pause" : "Play",
                       viewer.isPlaying ? .pause : .resume, size: 40)
                skipButton(forward: true)
                button("forward.end.fill", "Next", .next)
                Button {
                    Haptics.tap()
                    touched()
                    viewer.togglePictureInPicture()
                } label: {
                    Image(systemName: "pip.enter").font(.system(size: 24)).frame(width: 56, height: 56).contentShape(Rectangle())
                }
                .accessibilityLabel("Picture in Picture")
            }
            options
        }
        .foregroundStyle(.white)
        .onAppear { loadStoryboard() }
        .onChange(of: viewer.details?.storyboard) { _ in loadStoryboard() }
        .onChange(of: viewer.current?.videoID) { _ in loadStoryboard() }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(16)
    }
}

struct IdleView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var viewer: ViewerController
    let onPair: () -> Void

    private var pairedLine: String {
        settings.paired.isEmpty
            ? "Not paired yet."
            : "Paired with " + settings.paired.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // This screen can stay up for hours with the display kept awake, so nudge it each minute against burn-in.
            TimelineView(.periodic(from: .now, by: 60)) { t in
                let m = Int(t.date.timeIntervalSinceReferenceDate / 60)
                content.offset(x: CGFloat(m % 5 - 2) * 10, y: CGFloat(m % 3 - 1) * 10)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                Image(systemName: "tv").font(.system(size: 64, weight: .light)).accessibilityHidden(true)
                Text(settings.name).font(.largeTitle.bold())
                if viewer.denied {
                    Text("Local Network access is off").font(.title3).foregroundStyle(.orange)
                    Text("Other devices cannot find this viewer until you allow it in Settings.")
                        .font(.title3).foregroundStyle(.secondary)
                } else {
                    Text("Ready to receive videos").font(.title2).foregroundStyle(.secondary)
                    Text("Open TubeRemote on another device and choose this viewer.")
                        .font(.title3).foregroundStyle(.secondary)
                    Text(pairedLine).font(.title3).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            if viewer.denied {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            } else {
                Button(action: onPair) { Label("Pair a Device", systemImage: "link") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

/// The description or comments beside the video. The remote opens it, picks the tab and scrolls it.
struct SwipeAway<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @State private var drag: CGFloat = 0

    var body: some View {
        content
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 5, height: 44)
                    .padding(.leading, 6)
                    .frame(width: 30, height: 120, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { drag = max(0, $0.translation.width) }
                            .onEnded { v in
                                if v.translation.width > 80 || v.predictedEndTranslation.width > 200 {
                                    Haptics.tap()
                                    withAnimation(.easeOut(duration: 0.2)) { drag = 600 }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onClose() }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                                }
                            }
                    )
                    .accessibilityHidden(true)
            }
            .offset(x: drag)
    }
}

struct PanelClose: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Hide")
    }
}

struct RichPanel: View {
    @EnvironmentObject var viewer: ViewerController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewer.richTab == 1 ? "Comments" : "Description").font(.headline)
                Spacer()
                PanelClose { viewer.handle(.setRichView(false), from: nil) }
            }
            .padding(.leading, 16)
            Group {
                if viewer.richTab == 1 {
                    CommentsList(details: viewer.details, follow: viewer.richScroll)
                } else if let info = viewer.details?.info {
                    DescriptionLines(info: info, follow: viewer.richScroll)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id("\(viewer.details?.videoID ?? "")\(viewer.richTab)")
        }
        .background(.regularMaterial)
    }
}

struct QueueSidebar: View {
    @EnvironmentObject var viewer: ViewerController
    var onClose: () -> Void = {}
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Picker("List", selection: $tab) {
                    Text("Up next").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                PanelClose(action: onClose)
            }
            .padding(.leading)
            .padding(.top, 4)
            if tab == 0 {
                QueueList(
                    items: viewer.queue,
                    onPlay: { viewer.handle(.playQueueItem($0.id), from: nil) },
                    onRemove: { viewer.handle(.remove($0.id), from: nil) },
                    onMove: { from, to in
                        var q = viewer.queue
                        q.move(fromOffsets: from, toOffset: to)
                        viewer.handle(.reorder(q.map(\.id)), from: nil)
                    },
                    onClear: { viewer.handle(.clearQueue, from: nil) },
                    autoplayNext: viewer.autoplay ? viewer.autoplayNext : nil,
                    onAddNext: { viewer.handle(.enqueue($0), from: nil) },
                    onAnother: { viewer.handle(.autoplayAnother, from: nil) })
            } else {
                HistoryList(
                    items: viewer.history,
                    onReplay: { viewer.handle(.play($0), from: nil) },
                    onRequeue: { viewer.handle(.enqueue($0), from: nil) },
                    onClear: { viewer.handle(.clearHistory, from: nil) })
            }
        }
        .background(.regularMaterial)
    }
}

/// Browse YouTube on the viewer itself; actions go straight to the local queue.
struct LocalBrowse: View {
    @EnvironmentObject var browser: Browser
    @EnvironmentObject var viewer: ViewerController
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false

    private func send(_ action: QueueAction) {
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            guard let item = await browser.makeItem() else { return }
            viewer.handle(action.command(item), from: nil)
            browser.pause()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Hosted(view: browser.webView).background(Color.youTubePage.ignoresSafeArea())
                if browser.videoID != nil {
                    ActionBar(target: "this device", enabled: !sending, onAction: send)
                }
            }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { BrowserBack() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .pairingPrompt()
        }
        .onAppear { browser.ensureLoaded() }
        // Tapping play on the page plays the video on this viewer and closes the browser.
        .onReceive(browser.playTapped) { _ in
            send(.playNow)
            dismiss()
        }
    }
}

/// Every paired device, with the ones connected right now first, and devices that connected but are not paired yet.
struct PairSheet: View {
    @EnvironmentObject var viewer: ViewerController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: PairedDevice?

    private func live(_ d: PairedDevice) -> PendingPeer? { viewer.connected.first { $0.key == d.key } }

    private var devices: [PairedDevice] {
        settings.paired.sorted { a, b in
            let la = live(a) != nil, lb = live(b) != nil
            return la != lb ? la : a.name < b.name
        }
    }

    private func row(_ d: PairedDevice) -> some View {
        let peer = live(d)
        return HStack(spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(peer == nil ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer?.name ?? d.name)
                Text(peer == nil ? "Not connected" : "Connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let peer {
                Button("Disconnect", role: .destructive) {
                    Haptics.warning()
                    viewer.disconnect(peer)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(minHeight: 44)
        .swipeActions { Button("Forget", role: .destructive) { forgetting = d } }
    }

    var body: some View {
        NavigationStack {
            List {
                if !settings.paired.isEmpty {
                    Section {
                        ForEach(devices) { row($0) }
                    } header: {
                        Text("Paired devices")
                    } footer: {
                        Text("Disconnect closes the connection but keeps the pairing; the device reconnects when its owner chooses this viewer again. Swipe a device to forget it. Without Pro, a viewer serves one remote at a time; Pro on this device or on any connected remote lifts that.")
                    }
                }
                if viewer.pending.isEmpty {
                    if settings.paired.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "iphone").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text("No devices yet. Open the app on the other device in Remote mode.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section("Waiting to pair") {
                        ForEach(viewer.pending) { p in
                            Button {
                                Haptics.tap()
                                viewer.beginPair(p)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "iphone").foregroundStyle(.tint).frame(width: 28)
                                    Text(p.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Forget \(forgetting?.name ?? "this device")?",
                isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                titleVisibility: .visible,
                presenting: forgetting
            ) { d in
                Button("Forget", role: .destructive) {
                    settings.paired.removeAll { $0.key == d.key }
                }
            } message: { _ in
                Text("It is disconnected now and must pair again to reconnect.")
            }
        }
        .presentationDetents([.medium, .large])
        .pairingPrompt()
    }
}
