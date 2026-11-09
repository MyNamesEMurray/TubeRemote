import SwiftUI

// MARK: Browsing + mini player

struct RemoteView: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var browser: Browser
    @Binding var showSettings: Bool
    @State private var showPicker = false
    @State private var showNow = false

    var body: some View {
        NavigationStack {
            HostedWebView(webView: browser.webView)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if browser.canGoBack {
                            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("Back")
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        ConnectionChip { showPicker = true }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        ModeMenu()
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if browser.videoID != nil {
                            if let c = remote.active {
                                ActiveActionBar(client: c)
                            } else {
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
                        if let c = remote.active {
                            MiniPlayer(client: c) { showNow = true }
                        }
                    }
                }
        }
        .sheet(isPresented: $showPicker) { DevicePicker() }
        .sheet(isPresented: $showNow) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct ConnectionChip: View {
    @EnvironmentObject var remote: RemoteController
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
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityHint("Opens the viewer list")
        }
    }
}

struct ChipInner: View {
    @ObservedObject var client: RemoteClient
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle().fill(client.connected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(client.title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("\(client.title), \(client.connected ? "connected" : "connecting")")
        .accessibilityHint("Opens the viewer list")
    }
}

struct ActionBar: View {
    @EnvironmentObject var settings: AppSettings
    let target: String
    let enabled: Bool
    var showHere = true
    let onAction: (QueueAction) -> Void
    var onHere: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.tap()
                onAction(settings.queueAction)
            } label: {
                Label(settings.queueAction.title(on: target), systemImage: settings.queueAction.icon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!enabled)

            Menu {
                ForEach(QueueAction.allCases.filter { $0 != settings.queueAction }) { a in
                    Button { Haptics.tap(); onAction(a) } label: { Label(a.title(on: target), systemImage: a.icon) }
                        .disabled(!enabled)
                }
                if showHere {
                    Button { Haptics.tap(); onHere() } label: { Label("Play here", systemImage: "iphone") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More ways to send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ActiveActionBar: View {
    @ObservedObject var client: RemoteClient
    @EnvironmentObject var browser: Browser

    var body: some View {
        ActionBar(target: client.title, enabled: client.connected, onAction: { a in
            Task { @MainActor in
                guard let item = await browser.makeItem() else { return }
                client.send(a.command(item))
                browser.pause()
                Haptics.success()
            }
        }, onHere: { browser.play() })
    }
}

struct MiniPlayer: View {
    @ObservedObject var client: RemoteClient
    let open: () -> Void

    private var fraction: Double {
        guard let s = client.state, s.duration > 0 else { return 0 }
        return min(max(s.position / s.duration, 0), 1)
    }

    var body: some View {
        if let cur = client.state?.current {
            let playing = client.state?.isPlaying == true
            HStack(spacing: 4) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Thumb(url: cur.thumbnailURL, radius: 8).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cur.title).font(.headline).lineLimit(1)
                            Text(client.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(cur.title) on \(client.title)")
                .accessibilityHint("Opens Now Playing")

                Button {
                    Haptics.tap()
                    client.send(playing ? .pause : .resume)
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel(playing ? "Pause" : "Play")
                Button {
                    Haptics.tap()
                    client.send(.next)
                } label: {
                    Image(systemName: "forward.fill").font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
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

// MARK: Device picker

struct DevicePicker: View {
    @EnvironmentObject var remote: RemoteController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if remote.devices.isEmpty {
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
                            remote.select(c)
                            dismiss()
                        }, onPair: {
                            Haptics.tap()
                            remote.select(c)
                            c.beginPair()
                            dismiss()
                        })
                    }
                } footer: {
                    Text("Open the app on another device and switch it to Viewer mode.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Viewers")
            .navigationBarTitleDisplayMode(.inline)
            .pairingPrompt()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
        if client.needsPairing { return "Not paired" }
        guard client.connected, let s = client.state else {
            return client.detail.isEmpty ? "Connecting…" : "Connecting… \(client.detail)"
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let c = remote.active {
            NowPlayingContent(client: c, dismiss: { dismiss() })
        } else {
            EmptyState(symbol: "tv", title: "No Viewer Selected", message: "Choose a viewer to control playback.")
        }
    }
}

struct NowPlayingContent: View {
    private enum Panel { case queue, history }

    @ObservedObject var client: RemoteClient
    let dismiss: () -> Void
    @State private var panel: Panel?
    @State private var showPicker = false

    private func toggle(_ p: Panel, symbol: String, label: String) -> some View {
        let on = panel == p
        return Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panel = on ? nil : p }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(on ? Color.accentColor : Color.clear))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.connected {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reconnecting to \(client.title)…").font(.footnote)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 4)
                    .transition(.opacity)
                }
                Group {
                    switch panel {
                    case .queue: RemoteQueue(client: client)
                    case .history: RemoteHistory(client: client)
                    case nil: ControlsPane(client: client)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: client.connected)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 48) {
                    toggle(.queue, symbol: "list.bullet", label: "Queue")
                    toggle(.history, symbol: "clock", label: "History")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: dismiss) }
                ToolbarItem(placement: .primaryAction) {
                    Button { showPicker = true } label: { Label(client.title, systemImage: "tv") }
                        .accessibilityLabel("Viewer: \(client.title)")
                        .accessibilityHint("Opens the viewer list")
                }
            }
            .sheet(isPresented: $showPicker) { DevicePicker() }
            .pairingPrompt()
        }
    }
}

struct ControlsPane: View {
    @ObservedObject var client: RemoteClient
    @State private var scrub: Double?
    @State private var vol: Float?

    var body: some View {
        if let s = client.state, let cur = s.current {
            let pos = scrub ?? s.position
            ScrollView {
                VStack(spacing: 20) {
                    Thumb(url: cur.thumbnailURL, radius: 14)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                        .padding(.top, 8)
                    VStack(spacing: 4) {
                        Text(cur.title).font(.title3.bold()).multilineTextAlignment(.center)
                        if !cur.channel.isEmpty {
                            Text(cur.channel).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(get: { pos }, set: { scrub = $0 }),
                            in: 0...max(s.duration, 1)
                        ) { editing in
                            if !editing, let v = scrub {
                                client.state?.position = v
                                client.send(.seek(v))
                                scrub = nil
                                Haptics.tap()
                            }
                        }
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(clock(pos)) of \(clock(s.duration))")
                        HStack {
                            Text(clock(pos))
                            Spacer()
                            Text("-" + clock(max(s.duration - pos, 0)))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                    HStack(spacing: 0) {
                        transport("backward.end.fill", "Previous track", size: 28) { client.send(.previous) }
                        transport("gobackward.10", "Back 10 seconds", size: 28) { client.send(.skip(-10)) }
                        transport(s.isPlaying ? "pause.fill" : "play.fill", s.isPlaying ? "Pause" : "Play", size: 44) {
                            client.send(s.isPlaying ? .pause : .resume)
                        }
                        transport("goforward.10", "Forward 10 seconds", size: 28) { client.send(.skip(10)) }
                        transport("forward.end.fill", "Next track", size: 28) { client.send(.next) }
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
                            value: Binding(get: { vol ?? s.volume }, set: { vol = $0; client.send(.setVolume($0)) }),
                            in: 0...1
                        ) { editing in if !editing { vol = nil } }
                        .accessibilityLabel("Volume")
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
        } else {
            EmptyState(symbol: "play.circle", title: "Nothing Playing", message: "Send a video from the browser to start.")
        }
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

struct RemoteQueue: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        QueueList(
            items: client.state?.queue ?? [],
            onPlay: { client.send(.playQueueItem($0.id)) },
            onRemove: { client.send(.remove($0.id)) },
            onMove: { from, to in
                guard var q = client.state?.queue else { return }
                q.move(fromOffsets: from, toOffset: to)
                client.state?.queue = q
                client.send(.reorder(q.map(\.id)))
            },
            onClear: { client.send(.clearQueue) })
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
