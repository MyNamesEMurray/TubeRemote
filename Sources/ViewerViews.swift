import SwiftUI
import MediaPlayer

struct ViewerView: View {
    @EnvironmentObject var viewer: ViewerController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var showSettings: Bool
    @State private var showQueue = false
    @State private var showBrowse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
                HostedWebView(webView: viewer.webView)
                if showQueue && hSize == .regular { QueueSidebar().frame(width: 320) }
            }
            if viewer.current == nil { IdleView() }
            // Off-screen volume slider; the only way to set system volume from an app.
            VolumeHost(view: viewer.volumeView).frame(width: 10, height: 10).opacity(0.01).allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            if showQueue && hSize == .compact { QueueSidebar().frame(width: 300) }
        }
        .overlay(alignment: .top) {
            if let t = viewer.toast {
                Text(t)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { menu }
        .animation(.default, value: viewer.toast)
        .animation(.default, value: showQueue)
        .sheet(isPresented: $showBrowse) { LocalBrowse() }
        .preferredColorScheme(.dark)
    }

    private var menu: some View {
        Menu {
            Button { showBrowse = true } label: { Label("Browse YouTube", systemImage: "safari") }
            Button { showQueue.toggle() } label: { Label(showQueue ? "Hide queue" : "Show queue", systemImage: "list.bullet") }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            ModeMenu()
        } label: {
            Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.7)).padding(12)
        }
    }
}

struct VolumeHost: UIViewRepresentable {
    let view: MPVolumeView
    func makeUIView(context: Context) -> MPVolumeView { view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct IdleView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "tv").font(.system(size: 56))
                Text(settings.name).font(.largeTitle.bold())
                Text("Ready to receive videos").foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }
}

struct QueueSidebar: View {
    @EnvironmentObject var viewer: ViewerController
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
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
        VStack(spacing: 0) {
            HStack {
                if browser.canGoBack {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
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
    }
}
