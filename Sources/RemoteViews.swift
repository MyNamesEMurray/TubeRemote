import SwiftUI

// MARK: Browsing + bottom bar

struct RemoteView: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var browser: Browser
    @EnvironmentObject var pro: ProStore
    @Binding var showSettings: Bool
    @State private var showPicker = false
    @State private var showNow = false
    @State private var sending = false
    @State private var showPaywall = false
    @State private var note: String?
    @AppStorage("seenSendTip") private var seenTip = false

    var body: some View {
        NavigationStack {
            Hosted(view: browser.webView)
                .background(Color.youTubePage.ignoresSafeArea())
                .overlay(alignment: .top) {
                    if let note {
                        Text(note)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .glassBackground(Capsule(), .regularMaterial)
                            .padding(8)
                            .transition(.opacity)
                    } else if !seenTip { tip }
                }
                .animation(.easeInOut(duration: 0.3), value: note)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { BrowserNav() }
                    ToolbarItem(placement: .principal) {
                        ConnectionChip { showPicker = true }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let c = remote.active { ResumeQueueBar(client: c) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let c = remote.active {
                        RemoteBar(client: c, canSend: browser.videoID != nil, pageVideoID: browser.videoID, hasPlaylist: browser.playlistID != nil,
                                  sending: sending, open: { showNow = true }, send: { send($0, to: c) }, play: { playTapped() },
                                  sendPlaylist: { sendPlaylist($0, reversed: $1, to: c) }, here: { browser.play() })
                    } else if browser.videoID != nil {
                        Button { showPicker = true } label: {
                            Label("Choose a Viewer", systemImage: "tv").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                }
        }
        .onAppear { browser.ensureLoaded() }
        .onChange(of: browser.videoID) { if $0 != nil { seenTip = true } }
        .onReceive(browser.playTapped) { _ in playTapped() }
        .sheet(isPresented: $showPicker) { DevicePicker() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showNow) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var tip: some View {
        HStack(spacing: 4) {
            Text("Find a video, then tap Send to play it on your viewer.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Button { seenTip = true } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.leading, 16)
        .glassBackground(RoundedRectangle(cornerRadius: 16, style: .continuous), .regularMaterial)
        .padding(8)
    }

    private func send(_ action: QueueAction, to c: RemoteClient) {
        if c.needsPairing {
            Haptics.tap()
            c.beginPair()
            return
        }
        guard c.connected else {
            Haptics.warning()
            showPicker = true
            return
        }
        guard !sending else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            guard let item = await browser.makeItem() else { return }
            c.send(action.command(item))
            browser.pause()
            Haptics.success()
        }
    }

    private func show(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if note == text { note = nil } }
    }

    /// Reads the open playlist from the page and sends all of it to the viewer in one message.
    private func sendPlaylist(_ action: QueueAction, reversed: Bool, to c: RemoteClient) {
        guard pro.has(c.state) else { showPaywall = true; return }
        if c.needsPairing {
            Haptics.tap()
            c.beginPair()
            return
        }
        guard c.connected else {
            Haptics.warning()
            showPicker = true
            return
        }
        guard let id = browser.playlistID, !sending else { return }
        sending = true
        show("Reading the playlist…")
        Task { @MainActor in
            defer { sending = false }
            guard let read = await browser.playlistItems(id), !read.items.isEmpty else {
                Haptics.warning()
                show("Couldn't read this playlist. It may be private, or YouTube changed its page.")
                return
            }
            let items = reversed ? Array(read.items.reversed()) : read.items
            c.send(.playlist(items, action))
            browser.pause()
            Haptics.success()
            // Only the first 200 can be read, so a reversed long playlist does not start from its true last video.
            show("Sent \(items.count) videos to \(c.title)" + (read.truncated ? (reversed ? ". Only the first \(items.count) could be read, so the reverse starts there." : ". Only the first \(items.count) could be read.") : ""))
        }
    }

    /// The person tapped play on the page's own player: play that video on the viewer straight away.
    private func playTapped() {
        guard let c = remote.active else { showPicker = true; return }
        if c.connected, let id = browser.videoID, c.state?.current?.videoID == id {
            // Already loaded on the viewer: resume instead of starting over.
            c.send(.resume)
            Haptics.tap()
        } else {
            send(.playNow, to: c)
        }
    }
}

struct ConnectionChip: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var browser: Browser
    let onTap: () -> Void

    var body: some View {
        if let c = remote.active {
            ChipInner(client: c, onTap: onTap)
        } else {
            Button(action: onTap) {
                Label("Choose Viewer", systemImage: "tv")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .glassBackground(Capsule(), .thinMaterial)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityHint("Opens the viewer list")
            .onAppear { browser.target = "" }
        }
    }
}

struct ChipInner: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var browser: Browser
    let onTap: () -> Void

    private var coverLabel: String { client.needsPairing ? "Pair with \(client.title)" : "Play on \(client.title)" }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // A spinner, not just a colour, so the state reads without colour vision.
                if client.connected {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                } else if client.needsPairing {
                    Image(systemName: "link").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                } else if client.released || client.busy {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(client.needsPairing ? "Pair with \(client.title)" : client.title)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .glassBackground(Capsule(), .thinMaterial)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(client.title), \(client.needsPairing ? "not paired" : client.connected ? "connected" : "connecting")")
        .accessibilityHint("Opens the viewer list")
        // The play cover on the YouTube page names the viewer.
        .onAppear { browser.target = coverLabel }
        .onChange(of: coverLabel) { browser.target = $0 }
    }
}

/// Send bar for browsing on the viewer itself.
struct ActionBar: View {
    let target: String
    let enabled: Bool
    let onAction: (QueueAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.tap()
                onAction(.playNow)
            } label: {
                Label(QueueAction.playNow.title(on: target), systemImage: QueueAction.playNow.icon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            QueueMenu(target: target, title: target, active: true, sending: !enabled, send: onAction)
        }
        .disabled(!enabled)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One bottom bar: what the viewer is playing, play/pause, and the Send button when a video page is open.
struct RemoteBar: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var pro: ProStore
    @State private var showPaywall = false
    let canSend: Bool
    let pageVideoID: String?
    let hasPlaylist: Bool
    let sending: Bool
    let open: () -> Void
    let send: (QueueAction) -> Void
    let play: () -> Void
    let sendPlaylist: (QueueAction, Bool) -> Void
    let here: () -> Void

    private var fraction: Double {
        guard let s = client.state, s.duration > 0 else { return 0 }
        return min(max(s.position / s.duration, 0), 1)
    }

    var body: some View {
        let cur = client.state?.current
        let playing = client.state?.isPlaying == true
        if cur != nil || canSend || hasPlaylist {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        if let cur { Thumb(url: cur.thumbnailURL, radius: 8).frame(width: 44, height: 44) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cur?.title ?? (client.needsPairing ? "Not paired" : "Nothing playing")).font(.headline).lineLimit(1)
                            Text(client.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cur.map { "Now playing: \($0.title) on \(client.title)" } ?? "Nothing playing on \(client.title)")
                .accessibilityHint("Opens Now Playing")

                if client.state?.adSkippable == true {
                    Button {
                        Haptics.tap()
                        if pro.has(client.state) { client.send(.skipAd) } else { showPaywall = true }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Skip Ad")
                            if !pro.has(client.state) { Image(systemName: "lock.fill").font(.caption2) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: 44)
                } else if canSend && (pageVideoID != cur?.videoID || client.needsPairing) {
                    PlayMenu(target: client.key, title: client.title, pairing: client.needsPairing,
                             active: client.connected || client.needsPairing, sending: sending, play: play, here: here)
                        .equatable()
                } else if cur != nil {
                    Button {
                        Haptics.tap()
                        client.send(playing ? .pause : .resume)
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor, in: Circle())
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(playing ? "Pause" : "Play")
                }
                if hasPlaylist {
                    PlaylistMenu(target: client.key, active: client.connected || client.needsPairing, locked: !pro.has(client.state), send: sendPlaylist)
                        .equatable()
                }
                if canSend && !client.needsPairing {
                    QueueMenu(target: client.key, title: client.title, active: client.connected, sending: sending, send: send)
                        .equatable()
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * fraction, height: 2)
                        .animation(.linear(duration: 0.5), value: fraction)
                }
                .frame(height: 2)
            }
        }
    }
}

/// Offered when the viewer has nothing queued or playing and this remote still holds a saved queue.
struct ResumeQueueBar: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pro: ProStore
    @State private var showPreview = false

    private func resume() {
        Haptics.tap()
        client.send(.playlist(settings.savedQueue.items, .playNow))
    }

    var body: some View {
        if settings.saveQueue, pro.has(client.state), client.connected, let s = client.state,
           s.current == nil, s.queue.isEmpty, !settings.savedQueue.isEmpty {
            HStack(spacing: 8) {
                Button(action: resume) {
                    Label("Resume queue (\(settings.savedQueue.count))", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Button {
                    Haptics.tap()
                    showPreview = true
                } label: {
                    Image(systemName: "list.bullet").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Preview the saved queue")
                Button {
                    Haptics.tap()
                    settings.savedQueue = SavedQueue()
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Discard the saved queue")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .sheet(isPresented: $showPreview) {
                SavedQueueSheet(saved: settings.savedQueue, title: client.title) {
                    showPreview = false
                    resume()
                }
            }
        }
    }
}

/// The saved queue as it would play, before any of it is sent.
struct SavedQueueSheet: View {
    let saved: SavedQueue
    let title: String
    let resume: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let c = saved.current {
                    Section("Was playing") {
                        VideoRow(item: c)
                        if saved.position > 5 {
                            Text("Resumes at \(clock(saved.position))").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if !saved.queue.isEmpty {
                    Section("Up Next") { ForEach(saved.queue) { VideoRow(item: $0) } }
                }
            }
            .navigationTitle("Saved queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Resume on \(title)", action: resume) }
            }
        }
    }
}

/// Adds the whole playlist the open page belongs to. Compared by the viewer and two flags only: the bar is redrawn each time the
/// viewer reports its position, and a menu that is redrawn while open pulses.
struct PlaylistMenu: View, Equatable {
    let target: String
    let active: Bool
    let locked: Bool
    let send: (QueueAction, Bool) -> Void

    static func == (a: PlaylistMenu, b: PlaylistMenu) -> Bool { a.target == b.target && a.active == b.active && a.locked == b.locked }

    var body: some View {
        Menu {
            Section("In playlist order") {
                ForEach(QueueAction.allCases) { a in
                    Button { Haptics.tap(); send(a, false) } label: { Label(a.playlistTitle, systemImage: a.icon) }
                }
            }
            Section("Reversed") {
                ForEach(QueueAction.allCases) { a in
                    Button { Haptics.tap(); send(a, true) } label: { Label(a.playlistTitle, systemImage: "arrow.up.arrow.down") }
                }
            }
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if locked { Image(systemName: "lock.fill").font(.system(size: 9)).padding(6) }
                }
                .opacity(active ? 1 : 0.5)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Add the whole playlist")
    }
}

/// Tap plays the open video on the viewer; touch and hold offers playing it here instead. Compared by what it shows, for
/// the same reason as `PlaylistMenu`.
struct PlayMenu: View, Equatable {
    let target: String
    let title: String
    let pairing: Bool
    let active: Bool
    let sending: Bool
    let play: () -> Void
    let here: () -> Void

    static func == (a: PlayMenu, b: PlayMenu) -> Bool {
        a.target == b.target && a.title == b.title && a.pairing == b.pairing && a.active == b.active && a.sending == b.sending
    }

    var body: some View {
        Menu {
            Button { Haptics.tap(); here() } label: { Label("Play here", systemImage: "iphone") }
        } label: {
            Image(systemName: pairing ? "link" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: Circle())
                .opacity(active && !sending ? 1 : 0.5)
                .frame(width: 44, height: 44)
        } primaryAction: {
            Haptics.tap()
            play()
        }
        .accessibilityLabel(pairing ? "Pair with \(title)" : "Play on \(title)")
        .accessibilityHint(pairing ? "Compare a code on both devices" : "Touch and hold to play it on this device instead")
    }
}

/// Tap adds the open video to the end of the queue; touch and hold chooses play next or the end.
struct QueueMenu: View, Equatable {
    let target: String
    let title: String
    let active: Bool
    let sending: Bool
    let send: (QueueAction) -> Void

    static func == (a: QueueMenu, b: QueueMenu) -> Bool {
        a.target == b.target && a.title == b.title && a.active == b.active && a.sending == b.sending
    }

    var body: some View {
        Menu {
            ForEach([QueueAction.playNext, .addToEnd]) { a in
                Button { Haptics.tap(); send(a) } label: { Label(a.title(on: title), systemImage: a.icon) }
            }
        } label: {
            Image(systemName: QueueAction.addToEnd.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemFill), in: Circle())
                .opacity(active && !sending ? 1 : 0.5)
                .frame(width: 44, height: 44)
        } primaryAction: {
            Haptics.tap()
            send(.addToEnd)
        }
        .accessibilityLabel("Add to the end of the queue on \(title)")
        .accessibilityHint("Touch and hold to play it next instead")
    }
}

// MARK: Device picker

struct DevicePicker: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: PairedDevice?

    private var away: [PairedDevice] {
        settings.paired.filter { p in !remote.devices.contains { $0.key == p.key } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if remote.denied {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Local Network access is off").font(.headline)
                            Text("TubeRemote needs it to find your other devices.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Open Settings") {
                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    } else if remote.devices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Searching for Viewers").font(.headline)
                                Text("Make sure other devices are on the same Wi-Fi network.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(remote.devices) { c in
                        DeviceRow(client: c, selected: c.key == remote.selectedKey, onTap: {
                            Haptics.tap()
                            c.reconnect()
                            remote.select(c)
                            dismiss()
                        }, onPair: {
                            Haptics.tap()
                            remote.select(c)
                            c.beginPair()
                            dismiss()
                        })
                        .swipeActions {
                            if let p = settings.paired(c.key) { Button("Forget", role: .destructive) { forgetting = p } }
                        }
                    }
                } footer: {
                    Text("Open the app on another device and switch it to Viewer mode.")
                }
                if !away.isEmpty {
                    Section("Not found") {
                        ForEach(away) { p in
                            Label(p.name, systemImage: "tv")
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44)
                                .swipeActions { Button("Forget", role: .destructive) { forgetting = p } }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Viewers")
            .navigationBarTitleDisplayMode(.inline)
            .pairingPrompt()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                "Forget \(forgetting?.name ?? "this device")?",
                isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                titleVisibility: .visible,
                presenting: forgetting
            ) { d in
                Button("Forget", role: .destructive) { settings.paired.removeAll { $0.key == d.key } }
            } message: { _ in
                Text("It must pair again to reconnect.")
            }
        }
    }
}

struct DeviceRow: View {
    @ObservedObject var client: RemoteClient
    let selected: Bool
    let onTap: () -> Void
    let onPair: () -> Void

    private var status: String {
        if client.busy { return "In use by another remote. Pro lets several remotes share a viewer. Tap to retry." }
        if client.released { return "Disconnected by this viewer. Tap to reconnect." }
        if client.outdated { return "Update TubeRemote on both devices" }
        if client.needsPairing { return "Not paired" }
        guard client.connected, let s = client.state else {
            // The raw error is in the debug log.
            return client.detail.isEmpty ? "Connecting…" : "Can't reach this viewer. Retrying…"
        }
        return s.current.map { "Playing: \($0.title)" } ?? "Idle"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "tv").font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.title).font(.body).foregroundStyle(.primary)
                    Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle().fill(client.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Selects this viewer")

            if client.needsPairing {
                Button("Pair", action: onPair)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Pair with \(client.title)")
            } else if selected {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: Now Playing

struct NowPlayingView: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var browser: Browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let c = remote.active {
            NowPlayingContent(client: c, dismiss: { dismiss() }, openPage: { item in
                guard item.isValid, let url = URL(string: "https://www.youtube.com/watch?v=\(item.videoID)") else { return }
                browser.webView.load(URLRequest(url: url))
                dismiss()
            })
        } else {
            EmptyState(symbol: "tv", title: "No Viewer Selected", message: "Choose a viewer to control playback.")
        }
    }
}

struct NowPlayingContent: View {
    private enum Panel: Hashable { case controls, details, queue, history }

    @ObservedObject var client: RemoteClient
    let dismiss: () -> Void
    /// Opens the video's own YouTube page in the browser.
    let openPage: (VideoItem) -> Void
    @State private var panel: Panel
    @State private var showPicker = false
    @State private var keys = VolumeKeys()

    init(client: RemoteClient, dismiss: @escaping () -> Void, openPage: @escaping (VideoItem) -> Void = { _ in }) {
        self.client = client
        self.dismiss = dismiss
        self.openPage = openPage
        var start = Panel.controls
        #if DEBUG
        if ScreenshotStage.panel == "queue" { start = .queue } else if ScreenshotStage.panel == "history" { start = .history }
        #endif
        _panel = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.connected {
                    HStack(spacing: 8) {
                        if client.needsPairing {
                            Text("Not paired with \(client.title)").font(.footnote)
                            Button("Pair") {
                                Haptics.tap()
                                client.beginPair()
                            }
                            .font(.footnote.weight(.semibold))
                        } else if client.released || client.busy {
                            Text(client.busy ? "\(client.title) is in use by another remote" : "Disconnected by \(client.title)")
                                .font(.footnote)
                            Button("Reconnect") {
                                Haptics.tap()
                                client.reconnect()
                            }
                            .font(.footnote.weight(.semibold))
                        } else {
                            ProgressView()
                            Text("Reconnecting to \(client.title)…").font(.footnote)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassBackground(Capsule(), .regularMaterial)
                    .padding(.top, 4)
                    .transition(.opacity)
                }
                Group {
                    switch panel {
                    case .queue: RemoteQueue(client: client)
                    case .history: RemoteHistory(client: client)
                    case .controls: ControlsPane(client: client, open: openPage)
                    case .details: DetailsPane(client: client)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: client.connected)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Picker("Show", selection: $panel) {
                    Text("Controls").tag(Panel.controls)
                    if client.state?.richView != nil { Text("Details").tag(Panel.details) }
                    Text("Up Next").tag(Panel.queue)
                    Text("History").tag(Panel.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: dismiss) }
                // The toolbar button shows only its icon, so name the viewer under the title.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Now Playing").font(.headline)
                        Text("on \(client.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showPicker = true } label: { Label(client.title, systemImage: "tv").labelStyle(.titleAndIcon) }
                        .accessibilityLabel("Viewer: \(client.title)")
                        .accessibilityHint("Opens the viewer list")
                }
            }
            .sheet(isPresented: $showPicker) { DevicePicker() }
            .pairingPrompt()
        }
        .background(alignment: .topLeading) { Hosted(view: keys.view).frame(width: 10, height: 10).clipped().opacity(0.01).allowsHitTesting(false) }
        // While this screen is open the phone's volume buttons set the viewer's volume.
        .onAppear {
            keys.start { step in
                guard client.connected, let now = client.state?.volume else { return }
                let v = min(max(now + step, 0), 1)
                client.state?.volume = v
                client.send(.setVolume(v))
            }
        }
        .onDisappear { keys.stop() }
    }
}

struct ControlsPane: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var settings: AppSettings
    var open: (VideoItem) -> Void = { _ in }
    @EnvironmentObject var pro: ProStore
    @State private var showPaywall = false
    @State private var scrub: Double?
    @State private var scrubbing = false
    @StateObject private var storyboard = Storyboard()
    @State private var vol: Float?
    @State private var volSent = Date.distantPast
    @State private var held: (value: Double, until: Date)?

    var body: some View {
        if let s = client.state, let cur = s.current {
            // Right after a seek the viewer may still report the old position for a moment; keep showing where it was sent.
            let pos = scrub ?? held.flatMap { $0.until > Date() ? $0.value : nil } ?? s.position
            ScrollView {
                VStack(spacing: 20) {
                    Thumb(url: cur.artworkURL, fallback: cur.thumbnailURL, radius: 14)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                        .padding(.top, 8)
                    Button {
                        Haptics.tap()
                        open(cur)
                    } label: {
                        VStack(spacing: 4) {
                            (Text(cur.title) + Text(" \(Image(systemName: "arrow.up.right.square"))").foregroundColor(.secondary))
                                .font(.title3.bold()).multilineTextAlignment(.center)
                            if !cur.channel.isEmpty {
                                Text(cur.channel).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens the video's page to read its description and comments")
                    if s.duration <= 0, s.position > 5 {
                        // A live stream has no length to scrub through.
                        Text("LIVE")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.red, in: Capsule())
                    } else {
                    VStack(spacing: 2) {
                        ScrubBar(
                            value: scrub ?? (s.live == true && s.liveHead == true ? s.duration : pos),
                            maxValue: s.duration,
                            onScrub: { scrub = $0 },
                            onEnd: commitSeek,
                            onCancel: { scrub = nil },
                            onActive: { scrubbing = $0 },
                            preview: { storyboard.frame(at: $0) })
                        .animation(scrub == nil ? .linear(duration: 1) : nil, value: pos)
                        HStack {
                            Text(clock(pos))
                            Spacer()
                            if s.live == true {
                                LivePill(atHead: s.liveHead == true) { client.send(.goLive) }
                            } else {
                                Text("-" + clock(max(s.duration - pos, 0)))
                            }
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    }
                    HStack(spacing: 0) {
                        transport("backward.end.fill", "Previous track", size: 28) { client.send(.previous) }
                        skipButton(forward: false, s, pos)
                        transport(s.isPlaying ? "pause.fill" : "play.fill", s.isPlaying ? "Pause" : "Play", size: 44) {
                            client.send(s.isPlaying ? .pause : .resume)
                        }
                        skipButton(forward: true, s, pos)
                        transport("forward.end.fill", "Next track", size: 28) { client.send(.next) }
                    }
                    if s.adSkippable == true {
                        Button {
                            Haptics.tap()
                            if pro.has(client.state) { client.send(.skipAd) } else { showPaywall = true }
                        } label: {
                            HStack(spacing: 8) {
                                Label("Skip Ad", systemImage: "forward.fill")
                                if !pro.has(client.state) { GatedBadge() }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                    }
                    if let speed = s.speed { playbackOptions(s, speed: speed) }
                    HStack(spacing: 10) {
                        SleepTimerMenu(endsAt: s.sleepEndsAt, unlocked: s.sessionPro == true) { client.send(.setSleepTimer($0)) }
                            .equatable()
                        if let on = s.autoplay {
                            AutoplayButton(on: on, unlocked: s.sessionPro == true) { client.send(.setAutoplay($0)) }
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            Haptics.tap()
                            client.send(.setMuted(!s.muted))
                        } label: {
                            Image(systemName: s.muted ? "speaker.slash.fill" : "speaker.fill")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(s.muted ? "Unmute" : "Mute")
                        Slider(
                            value: Binding(get: { vol ?? s.volume }, set: { setVolume($0) }),
                            // Sixteen steps, the same as the hardware volume buttons.
                            in: 0...1, step: 0.0625
                        ) { editing in
                            if !editing, let v = vol {
                                client.send(.setVolume(v))
                                vol = nil
                            }
                        }
                        .accessibilityLabel("Volume")
                        .accessibilityValue("\(Int(((vol ?? s.volume) * 100).rounded())) percent")
                        Image(systemName: "speaker.wave.3.fill")
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .disabled(!client.connected)
            }
            .scrollDisabled(scrubbing)
            .onAppear { loadStoryboard() }
            .onChange(of: client.details?.storyboard) { _ in loadStoryboard() }
            .onChange(of: client.state?.current?.videoID) { _ in loadStoryboard() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        } else {
            EmptyState(symbol: "play.circle", title: "Nothing Playing", message: "Send a video from the browser to start.")
        }
    }

    /// Jumps to an exact time worked out here from what the slider shows, so quick taps add up and the viewer is not
    /// left to add to a position it may report late.
    private func jump(_ by: Double, from pos: Double, of duration: Double) {
        let t = max(0, duration > 0 ? min(pos + by, duration) : pos + by)
        held = (t, Date().addingTimeInterval(1.5))
        client.state?.position = t
        Log.add("jump to \(Int(t)) s")
        client.send(.seek(t))
        Haptics.tap()
    }

    private func commitSeek() {
        guard let v = scrub else { return }
        scrub = nil
        held = (v, Date().addingTimeInterval(1.5))
        client.state?.position = v
        Log.add("seek to \(Int(v)) s")
        client.send(.seek(v))
        Haptics.tap()
    }

    private static let speeds = playbackSpeeds

    private func rate(_ r: Double) -> String { rateLabel(r) }

    private func option(_ text: String, _ symbol: String, selected: Bool = false) -> some View {
        Pill(selected: selected) { Label(text, systemImage: symbol) }
    }

    private func check(_ text: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            if on { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
    }

    /// Speed, captions and quality on the viewer.
    private func playbackOptions(_ s: ViewerState, speed: Double) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Self.speeds, id: \.self) { r in check(rate(r), r == speed) { client.send(.setSpeed(r)) } }
            } label: {
                option(rate(speed), "speedometer")
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Playback speed, \(rate(speed))")
            Button {
                Haptics.tap()
                // While searching, a tap cancels the request.
                client.send(.setCaptions(s.captions != true && s.captionsStatus == nil))
            } label: {
                switch s.captionsStatus {
                case "none": option("No captions", "captions.bubble").opacity(0.5)
                case "searching": option("Finding captions…", "captions.bubble")
                default: option("Captions", s.captions == true ? "captions.bubble.fill" : "captions.bubble", selected: s.captions == true)
                }
            }
            .disabled(s.captionsStatus == "none")
            .accessibilityLabel(s.captionsStatus == "none" ? "This video has no captions"
                                : s.captions == true ? "Turn captions off" : "Turn captions on")
            if let qs = s.qualities, qs.count > 1 {
                Menu {
                    let auto = s.autoQuality != false
                    check("Auto", auto) { client.send(.setQuality("auto")) }
                    ForEach(qs, id: \.self) { q in
                        check(qualityLabel(q), !auto && q == s.quality) { client.send(.setQuality(q)) }
                    }
                } label: {
                    // In automatic mode say so, with the quality YouTube picked.
                    option(s.autoQuality != false ? "Auto \(qualityLabel(s.quality))" : qualityLabel(s.quality), "tv")
                }
                .menuOrder(.fixed)
                .accessibilityLabel("Quality, \(qualityLabel(s.quality))")
            }
        }
        .foregroundStyle(.primary)
    }

    /// A drag fires many times a second; send at most ten, then the final value on release.
    private func setVolume(_ v: Float) {
        vol = v
        guard Date().timeIntervalSince(volSent) > 0.1 else { return }
        volSent = Date()
        client.send(.setVolume(v))
    }

    private func loadStoryboard() {
        if let d = client.details, d.videoID == client.state?.current?.videoID {
            storyboard.load(spec: d.storyboard, videoID: d.videoID, duration: client.state?.duration ?? 0)
        } else {
            storyboard.reset()
        }
    }

    private func skipButton(forward: Bool, _ s: ViewerState, _ pos: Double) -> some View {
        let n = settings.skipSeconds
        return Button {
            guard !HoldToScan.justScanned else { return }
            jump(forward ? Double(n) : Double(-n), from: pos, of: s.duration)
        } label: {
            SkipIcon(seconds: n, forward: forward, size: 28)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(forward ? "Forward \(n) seconds" : "Back \(n) seconds")
        .accessibilityHint("Touch and hold to scan")
        .modifier(HoldToScan(direction: forward ? 1 : -1, send: { client.send(.scan($0, mute: settings.muteWhileScanning)) }, end: { client.send(.scanEnd($0)) }))
    }

    private func transport(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// The video's description and comments. Reading them here is free; showing them on the viewer, scrolled from here,
/// is the Pro rich video view.
struct DetailsPane: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var pro: ProStore
    @State private var showPaywall = false
    @State private var tab = 0
    @State private var top = 0

    private var richOn: Bool { client.state?.richView == true }
    private var details: VideoDetails? {
        client.details.flatMap { $0.videoID == client.state?.current?.videoID ? $0 : nil }
    }

    private func toggle() {
        Haptics.tap()
        guard pro.has(client.state) else { return showPaywall = true }
        if richOn {
            client.send(.setRichView(false))
        } else {
            client.send(.setRichView(true))
            client.send(.richTab(tab))
            client.send(.richScroll(top))
        }
    }

    private func report(_ i: Int) {
        top = i
        if richOn { client.send(.richScroll(i)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $tab) {
                    Text("Description").tag(0)
                    Text("Comments").tag(1)
                }
                .pickerStyle(.segmented)
                Button(action: toggle) {
                    Pill(selected: richOn) {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.righthalf.inset.filled")
                            Text("Show on viewer")
                            if !pro.has(client.state) { GatedBadge() }
                        }
                    }
                    .fixedSize()
                }
                .accessibilityLabel(richOn ? "Stop showing on the viewer" : "Show on the viewer")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Group {
                if tab == 0 {
                    if let info = details?.info {
                        DescriptionLines(info: info, onTop: report, onSeek: { client.send(.seek($0)) })
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    CommentsList(details: details, onTop: report, onNearEnd: { client.send(.moreComments) },
                                 onToggle: { client.send(.toggleComment($0)) })
                }
            }
            .id("\(client.state?.current?.videoID ?? "")\(tab)")
        }
        .onAppear { client.send(.watchDetails(true)) }
        .onDisappear { client.send(.watchDetails(false)) }
        .onChange(of: client.connected) { if $0 { client.send(.watchDetails(true)) } }
        .onChange(of: tab) { t in
            top = 0
            if richOn { client.send(.richTab(t)) }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

struct RemoteQueue: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        QueueList(
            items: client.state?.queue ?? [],
            onPlay: { client.send(.playQueueItem($0.id)) },
            onRemove: { item in
                // The row must leave the list now; waiting for the viewer's next state makes the list crash.
                client.state?.queue.removeAll { $0.id == item.id }
                client.send(.remove(item.id))
            },
            onMove: { from, to in
                guard var q = client.state?.queue else { return }
                q.move(fromOffsets: from, toOffset: to)
                client.state?.queue = q
                client.send(.reorder(q.map(\.id)))
            },
            onClear: { client.send(.clearQueue) },
            autoplayNext: client.state?.autoplay == true ? client.state?.autoplayNext : nil,
            onAddNext: { client.send(.enqueue($0)) },
            onAnother: { client.send(.autoplayAnother) })
    }
}

struct RemoteHistory: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        HistoryList(
            items: client.state?.history ?? [],
            onReplay: { client.send(.play($0)) },
            onRequeue: { client.send(.enqueue($0)) },
            onClear: { client.send(.clearHistory) })
    }
}
