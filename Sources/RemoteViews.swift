import SwiftUI

// MARK: Browsing + mini player

struct RemoteView: View {
    @EnvironmentObject var remote: RemoteController
    @EnvironmentObject var browser: Browser
    @Binding var showSettings: Bool
    @State private var showPicker = false
    @State private var showNow = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if browser.canGoBack {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                }
                Spacer()
                ConnectionChip { showPicker = true }
                ModeMenu()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HostedWebView(webView: browser.webView)

            if browser.videoID != nil {
                if let c = remote.active {
                    ActiveActionBar(client: c)
                } else {
                    Button("Choose a viewer…") { showPicker = true }
                        .buttonStyle(.bordered)
                        .padding(8)
                }
            }
            if let c = remote.active {
                MiniPlayer(client: c) { showNow = true }
            }
        }
        .sheet(isPresented: $showPicker) { DevicePicker() }
        .sheet(isPresented: $showNow) { NowPlayingView() }
    }
}

struct ConnectionChip: View {
    @EnvironmentObject var remote: RemoteController
    let onTap: () -> Void

    var body: some View {
        if let c = remote.active {
            ChipInner(client: c, onTap: onTap)
        } else {
            Button(action: onTap) { Label("Choose viewer", systemImage: "tv") }
                .buttonStyle(.bordered)
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
                Text(client.title).lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(QueueAction.allCases) { a in
                    Button { onAction(a) } label: { Label(a.title(on: target), systemImage: a.icon) }
                        .buttonStyle(.bordered)
                        .tint(a == settings.queueAction ? Color.accentColor : Color.gray)
                        .disabled(!enabled)
                }
                if showHere {
                    Button(action: onHere) { Label("Play here", systemImage: "iphone") }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
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
            }
        }, onHere: { browser.play() })
    }
}

struct MiniPlayer: View {
    @ObservedObject var client: RemoteClient
    let open: () -> Void

    var body: some View {
        if let cur = client.state?.current {
            HStack(spacing: 12) {
                Thumb(url: cur.thumbnailURL).frame(width: 64, height: 36)
                VStack(alignment: .leading) {
                    Text(cur.title).font(.subheadline.bold()).lineLimit(1)
                    Text(client.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    client.send(client.state?.isPlaying == true ? .pause : .resume)
                } label: {
                    Image(systemName: client.state?.isPlaying == true ? "pause.fill" : "play.fill")
                }
                Button { client.send(.next) } label: { Image(systemName: "forward.fill") }
            }
            .font(.title3)
            .padding(10)
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
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
                if remote.devices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for viewers on your network…")
                    }
                }
                ForEach(remote.devices) { c in
                    DeviceRow(client: c, selected: c.key == remote.selectedKey) {
                        remote.select(c)
                        dismiss()
                    }
                }
                Section(footer: Text("Open the app on another device and switch it to Viewer mode.")) { EmptyView() }
            }
            .navigationTitle("Viewers")
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

    private var status: String {
        guard client.connected, let s = client.state else { return "Connecting…" }
        return s.current.map { "Playing: \($0.title)" } ?? "Idle"
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.title).foregroundStyle(.primary)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
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
            Text("No viewer selected").foregroundStyle(.secondary)
        }
    }
}

struct NowPlayingContent: View {
    @ObservedObject var client: RemoteClient
    let dismiss: () -> Void
    @State private var tab = 0
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !client.connected {
                    Text("Reconnecting to \(client.title)…")
                        .font(.footnote).frame(maxWidth: .infinity).padding(6).background(Color.orange.opacity(0.3))
                }
                Picker("", selection: $tab) {
                    Text("Controls").tag(0)
                    Text("Queue").tag(1)
                    Text("History").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case 0: ControlsPane(client: client)
                case 1: RemoteQueue(client: client)
                default: RemoteHistory(client: client)
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: dismiss) }
                ToolbarItem(placement: .primaryAction) {
                    Button { showPicker = true } label: { Label(client.title, systemImage: "tv") }
                }
            }
            .sheet(isPresented: $showPicker) { DevicePicker() }
        }
    }
}

struct ControlsPane: View {
    @ObservedObject var client: RemoteClient
    @State private var scrub: Double?
    @State private var vol: Float?

    var body: some View {
        if let s = client.state, let cur = s.current {
            ScrollView {
                VStack(spacing: 18) {
                    Thumb(url: cur.thumbnailURL)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(spacing: 4) {
                        Text(cur.title).font(.title3.bold()).multilineTextAlignment(.center)
                        Text(cur.channel).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(get: { scrub ?? s.position }, set: { scrub = $0 }),
                            in: 0...max(s.duration, 1)
                        ) { editing in
                            if !editing, let v = scrub {
                                client.state?.position = v
                                client.send(.seek(v))
                                scrub = nil
                            }
                        }
                        HStack {
                            Text(clock(scrub ?? s.position))
                            Spacer()
                            Text(clock(s.duration))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 28) {
                        Button { client.send(.previous) } label: { Image(systemName: "backward.end.fill") }
                        Button { client.send(.skip(-10)) } label: { Image(systemName: "gobackward.10") }
                        Button { client.send(s.isPlaying ? .pause : .resume) } label: {
                            Image(systemName: s.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 60))
                        }
                        Button { client.send(.skip(10)) } label: { Image(systemName: "goforward.10") }
                        Button { client.send(.next) } label: { Image(systemName: "forward.end.fill") }
                    }
                    .font(.title)
                    HStack {
                        Button { client.send(.setMuted(!s.muted)) } label: {
                            Image(systemName: s.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 28)
                        }
                        Slider(
                            value: Binding(get: { vol ?? s.volume }, set: { vol = $0; client.send(.setVolume($0)) }),
                            in: 0...1
                        ) { editing in if !editing { vol = nil } }
                    }
                }
                .padding()
                .disabled(!client.connected)
            }
        } else {
            Text("Nothing playing").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
