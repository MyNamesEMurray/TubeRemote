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
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Always on screen so taps reach the player itself (Skip Ad, YouTube's own controls).
            menu.opacity(showQueue || viewer.current == nil ? 1 : 0.5)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewer.toast)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nowPlaying)
        .onChange(of: viewer.current?.videoID) { _ in announce() }
        .sheet(isPresented: $showBrowse) { LocalBrowse() }
        .sheet(isPresented: $showPair) { PairSheet() }
        .pairingPrompt()
        .preferredColorScheme(.dark)
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
                Hosted(view: browser.webView)
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
