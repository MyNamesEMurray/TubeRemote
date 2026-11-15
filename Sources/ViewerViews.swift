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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
                Hosted(view: viewer.webView)
                if showQueue && hSize == .regular {
                    Divider()
                    QueueSidebar().frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
            if viewer.current == nil { IdleView { showPair = true } }
            // Off-screen volume slider; the only way to set system volume from an app.
            Hosted(view: viewer.volumeView).frame(width: 10, height: 10).opacity(0.01).allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            if showQueue && hSize == .compact {
                QueueSidebar()
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
                ViewerControls(touched: keepControls)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Always on screen so taps reach the player itself (Skip Ad).
            menu.opacity(showMenu || showControls || showQueue || viewer.current == nil ? 1 : 0.5)
        }
        // The page reports taps on the video; nothing native sits on top of it to catch them.
        .onReceive(viewer.tapped) { _ in
            closeMenu()
            if showControls { hideWork?.cancel(); showControls = false } else { keepControls() }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
        .animation(.easeInOut(duration: 0.4), value: showMenu)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewer.toast)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nowPlaying)
        .onChange(of: viewer.current?.videoID) { _ in announce() }
        .sheet(isPresented: $showBrowse) { LocalBrowse() }
        .sheet(isPresented: $showPair) { PairSheet() }
        .pairingPrompt()
        .preferredColorScheme(.dark)
    }

    /// Shows the controls and hides them again after four quiet seconds.
    private func keepControls() {
        hideWork?.cancel()
        showControls = true
        let w = DispatchWorkItem { showControls = false }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
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

    private func menuRow(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
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
    /// Called on every interaction so the controls stay up while in use.
    let touched: () -> Void
    @State private var scrub: Double?

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

    private func option(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(.white.opacity(0.18), in: Capsule())
            .frame(minHeight: 44)
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

    /// Captions and quality, the same options the remote has.
    private var options: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(playbackSpeeds, id: \.self) { r in
                    check(rateLabel(r), r == viewer.speed) { viewer.handle(.setSpeed(r), from: nil) }
                }
            } label: {
                option(rateLabel(viewer.speed), "speedometer")
            }
            .accessibilityLabel("Playback speed, \(rateLabel(viewer.speed))")
            Button {
                Haptics.tap()
                touched()
                // While searching, a tap cancels the request.
                viewer.handle(.setCaptions(!viewer.captions && viewer.captionsStatus == nil), from: nil)
            } label: {
                switch viewer.captionsStatus {
                case "none": option("No captions", "captions.bubble").opacity(0.5)
                case "searching": option("Finding captions…", "captions.bubble")
                default: option("Captions", viewer.captions ? "captions.bubble.fill" : "captions.bubble")
                }
            }
            .disabled(viewer.captionsStatus == "none")
            .accessibilityLabel(viewer.captionsStatus == "none" ? "This video has no captions"
                                : viewer.captions ? "Turn captions off" : "Turn captions on")
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
                .accessibilityLabel("Quality, \(qualityLabel(viewer.quality))")
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let c = viewer.current {
                Text(c.title).font(.headline).lineLimit(1)
            }
            // Position is read on a timer here instead of being published, so only this row redraws.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let pos = scrub ?? viewer.position
                HStack(spacing: 12) {
                    Text(clock(pos))
                    Slider(
                        value: Binding(get: { pos }, set: { scrub = $0; touched() }),
                        in: 0...max(viewer.duration, 1)
                    ) { editing in
                        if !editing, let v = scrub {
                            viewer.handle(.seek(v), from: nil)
                            scrub = nil
                        }
                    }
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(clock(pos)) of \(clock(viewer.duration))")
                    Text(clock(viewer.duration))
                }
                .font(.caption.monospacedDigit())
            }
            HStack(spacing: 16) {
                button("backward.end.fill", "Previous", .previous)
                button("gobackward.10", "Back 10 seconds", .skip(-10))
                button(viewer.isPlaying ? "pause.fill" : "play.fill", viewer.isPlaying ? "Pause" : "Play",
                       viewer.isPlaying ? .pause : .resume, size: 40)
                button("goforward.10", "Forward 10 seconds", .skip(10))
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
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

struct QueueSidebar: View {
    @EnvironmentObject var viewer: ViewerController
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("List", selection: $tab) {
                Text("Up next").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
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
                    onClear: { viewer.handle(.clearQueue, from: nil) })
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

/// Remotes connected right now (each with a Disconnect button) and remotes that connected but are not paired yet.
struct PairSheet: View {
    @EnvironmentObject var viewer: ViewerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !viewer.connected.isEmpty {
                    Section {
                        ForEach(viewer.connected) { p in
                            HStack(spacing: 12) {
                                Image(systemName: "iphone").foregroundStyle(.tint).frame(width: 28)
                                Text(p.name)
                                Spacer()
                                Button("Disconnect", role: .destructive) {
                                    Haptics.warning()
                                    viewer.disconnect(p)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .frame(minHeight: 44)
                        }
                    } header: {
                        Text("Connected")
                    } footer: {
                        Text("A disconnected device stays paired. It reconnects when its owner chooses this viewer again.")
                    }
                }
                if viewer.pending.isEmpty {
                    if viewer.connected.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "iphone").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text("No devices found. Open the app on the other device in Remote mode.")
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
        }
        .presentationDetents([.medium])
        .pairingPrompt()
    }
}
