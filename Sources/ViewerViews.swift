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
    @State private var nowPlaying: VideoItem?
    @State private var nowWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
                HostedWebView(webView: viewer.webView)
                if showQueue && hSize == .regular {
                    Divider()
                    QueueSidebar().frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .accessibilityHidden(true)
            if viewer.current == nil { IdleView().allowsHitTesting(false) }
            // Off-screen volume slider; the only way to set system volume from an app.
            VolumeHost(view: viewer.volumeView).frame(width: 10, height: 10).opacity(0.01).allowsHitTesting(false)
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
            if let n = nowPlaying {
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
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showControls || showQueue || viewer.current == nil { menu.transition(.opacity) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewer.toast)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showControls)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nowPlaying)
        .onChange(of: viewer.current?.videoID) { _ in announce() }
        .sheet(isPresented: $showBrowse) { LocalBrowse() }
        .sheet(isPresented: $showPair) { PairSheet() }
        .pairingPrompt()
        .preferredColorScheme(.dark)
    }

    private func toggleControls() {
        Haptics.tap()
        hideWork?.cancel()
        if showControls { showControls = false; return }
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

    private var menu: some View {
        Menu {
            Button { showBrowse = true } label: { Label("Browse YouTube", systemImage: "safari") }
            Button { showPair = true } label: { Label("Pair a device", systemImage: "link") }
            Button { showQueue.toggle() } label: { Label(showQueue ? "Hide queue" : "Show queue", systemImage: "list.bullet") }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            ModeMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .padding(12)
        .accessibilityLabel("Menu")
    }
}

struct VolumeHost: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct IdleView: View {
    @EnvironmentObject var settings: AppSettings

    private var pairedLine: String {
        settings.paired.isEmpty
            ? "Not paired yet. Use the menu, then Pair a device."
            : "Paired with " + settings.paired.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "tv").font(.system(size: 64, weight: .light)).accessibilityHidden(true)
                Text(settings.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("Ready to receive videos").font(.title3).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    Text("Open TubeRemote on another device and choose this viewer.")
                    Text(pairedLine)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(32)
            .accessibilityElement(children: .combine)
        }
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HostedWebView(webView: browser.webView)
                if browser.videoID != nil {
                    ActionBar(target: "this device", enabled: true, showHere: false, onAction: { a in
                        Task { @MainActor in
                            guard let item = await browser.makeItem() else { return }
                            viewer.handle(a.command(item), from: nil)
                            browser.pause()
                        }
                    })
                }
            }
            .navigationTitle("YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if browser.canGoBack {
                        Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Remotes that connected but are not paired yet; picking one starts the code comparison.
struct PairSheet: View {
    @EnvironmentObject var viewer: ViewerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if viewer.pending.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("No unpaired devices found. Open the app on the other device in Remote mode.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    Section {
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
            .navigationTitle("Pair a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .pairingPrompt()
    }
}
