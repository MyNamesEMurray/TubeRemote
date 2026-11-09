import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer

/// Owns the queue, history and player. Remotes only send commands; this is the single source of truth.
final class ViewerController: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var current: VideoItem?
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var queue: [VideoItem] = []
    @Published var history: [VideoItem] = []
    @Published var toast: String?
    @Published var sleepEndsAt: Date?
    @Published var pending: [PendingPeer] = []
    @Published var volume: Float = AVAudioSession.sharedInstance().outputVolume

    let webView: WKWebView
    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    private let settings: AppSettings
    private let pairing: Pairing
    private let server = ViewerServer()
    private var jsReady = false
    private var pendingJS: [String] = []
    private var timer: Timer?
    private var toastWork: DispatchWorkItem?
    private var volumeObs: NSKeyValueObservation?
    private var premuteVolume: Float = 0.5
    private var running = false
    private var interruptObs: NSObjectProtocol?
    private var wasPlaying = false
    private var sleepAtEnd = false

    // YouTube rejects embeds whose origin is youtube.com itself (error 152); any other https origin works.
    private static let embedOrigin = "https://com.exaltedpixels.tuberemote"

    private static let playerHTML = """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}</style></head>
    <body><div id="p"></div>
    <script>
    var player, pending, post = function(o){ webkit.messageHandlers.yt.postMessage(o) };
    function build(id){
      player = new YT.Player('p', {width:'100%', height:'100%', videoId:id,
        playerVars:{playsinline:1, autoplay:1, rel:0, origin:'\(embedOrigin)'},
        events:{
          onReady:function(e){ e.target.playVideo() },
          onStateChange:function(e){ post({t:'state', s:e.data}) },
          onError:function(e){ post({t:'error', c:e.data}) }}});
    }
    function load(id){
      if (player && player.loadVideoById) { player.loadVideoById(id); return }
      if (window.YT && YT.Player) { if (!player) build(id) } else { pending = id }
    }
    function onYouTubeIframeAPIReady(){ if (pending) { build(pending); pending = null } }
    setInterval(function(){
      if (player && player.getCurrentTime) post({t:'time', pos:player.getCurrentTime(), dur:player.getDuration()})
    }, 500);
    post({t:'page'});
    </script>
    <script src="https://www.youtube.com/iframe_api"></script>
    </body></html>
    """

    init(settings: AppSettings, pairing: Pairing) {
        self.settings = settings
        self.pairing = pairing
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(Self.playerHTML, baseURL: URL(string: Self.embedOrigin))
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        Log.add("viewer start")
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        volume = session.outputVolume
        volumeObs = session.observe(\.outputVolume) { [weak self] s, _ in
            DispatchQueue.main.async { self?.volume = s.outputVolume }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        server.onCommand = { [weak self] cmd, who in self?.handle(cmd, from: who) }
        server.snapshot = { [weak self] in self?.snapshot() }
        server.paired = { [weak self] in self?.settings.paired($0) }
        server.onPair = { [weak self] m, reply in self?.pairing.receive(m, send: reply) }
        server.onPeers = { [weak self] in self?.pending = self?.server.pending ?? [] }
        pairing.onPaired = { [weak self] d in self?.server.markAuthed(key: d.key) }
        server.start(name: settings.name, key: settings.deviceKey)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickSleep(); self?.broadcast() }
        interruptObs = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.wasPlaying = self.isPlaying
                self.handle(.pause, from: nil)
            } else if wasPlaying, let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) {
                self.wasPlaying = false
                try? AVAudioSession.sharedInstance().setActive(true)
                self.handle(.resume, from: nil)
            }
        }
        let rc = MPRemoteCommandCenter.shared()
        for (c, cmd) in [(rc.playCommand, Command.resume), (rc.pauseCommand, .pause),
                         (rc.nextTrackCommand, .next), (rc.previousTrackCommand, .previous)] {
            c.addTarget { [weak self] _ in self?.handle(cmd, from: nil); return .success }
        }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.handle(.seek(e.positionTime), from: nil)
            return .success
        }
    }

    func stop() {
        guard running else { return }
        running = false
        Log.add("viewer stop")
        server.stop()
        timer?.invalidate()
        sleepEndsAt = nil
        sleepAtEnd = false
        volumeObs = nil
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        interruptObs = nil
        let rc = MPRemoteCommandCenter.shared()
        [rc.playCommand, rc.pauseCommand, rc.nextTrackCommand, rc.previousTrackCommand,
         rc.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.isIdleTimerDisabled = false
        js("player&&player.pauseVideo&&player.pauseVideo()")
        isPlaying = false
    }

    func beginPair(_ p: PendingPeer) {
        pairing.begin { [weak self] in self?.server.send(.pair($0), to: p.id) }
    }

    /// Re-advertise under a new device name.
    func rename() {
        if running { server.rename(name: settings.name, key: settings.deviceKey) }
    }

    // MARK: Commands

    /// `who` is the remote's name, or nil for local use (no toast).
    func handle(_ cmd: Command, from who: String?) {
        if let verb = apply(cmd), let who { flash("\(verb) from \(who)") }
        broadcast()
    }

    private func apply(_ cmd: Command) -> String? {
        switch cmd {
        case .play(let i):
            guard i.isValid else { return nil }
            start(i.fresh, pushPrevious: current?.videoID != i.videoID)
            return "Playing \(i.title)"
        case .playNext(let i):
            guard i.isValid else { return nil }
            queue.insert(i.fresh, at: 0)
            startIfIdle()
            return "Queued next: \(i.title)"
        case .enqueue(let i):
            guard i.isValid else { return nil }
            queue.append(i.fresh)
            startIfIdle()
            return "Added to queue: \(i.title)"
        case .pause:
            isPlaying = false
            js("player&&player.pauseVideo&&player.pauseVideo()")
            return "Paused"
        case .resume:
            isPlaying = true
            js("player&&player.playVideo&&player.playVideo()")
            return "Resumed"
        case .seek(let t):
            seek(t)
            return nil
        case .skip(let d):
            seek(position + d)
            return d > 0 ? "Skipped forward" : "Skipped back"
        case .next:
            advance()
            return "Next"
        case .previous:
            previous()
            return "Previous"
        case .setVolume(let v):
            setSystemVolume(v)
            return nil
        case .setMuted(let m):
            if m {
                if volume > 0.01 { premuteVolume = volume }
                setSystemVolume(0)
            } else {
                setSystemVolume(premuteVolume)
            }
            return m ? "Muted" : "Unmuted"
        case .remove(let id):
            queue.removeAll { $0.id == id }
            return nil
        case .reorder(let ids):
            var rest = queue, out: [VideoItem] = []
            for id in ids {
                if let i = rest.firstIndex(where: { $0.id == id }) { out.append(rest.remove(at: i)) }
            }
            queue = out + rest
            return nil
        case .playQueueItem(let id):
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return nil }
            let item = queue.remove(at: i)
            start(item)
            return "Playing \(item.title)"
        case .clearQueue:
            queue = []
            return "Queue cleared"
        case .clearHistory:
            history = []
            return nil
        case .setSleepTimer(let s):
            sleepAtEnd = false
            guard let s, s >= 0 else {
                sleepEndsAt = nil
                return "Sleep timer off"
            }
            if s == 0 {
                guard current != nil else { return nil }
                sleepAtEnd = true
                sleepEndsAt = Date().addingTimeInterval(max(duration - position, 0))
            } else {
                sleepEndsAt = Date().addingTimeInterval(s)
            }
            return "Sleep timer set"
        }
    }

    // MARK: Playback

    private func tickSleep() {
        if sleepAtEnd {
            sleepEndsAt = Date().addingTimeInterval(max(duration - position, 0))
        } else if let d = sleepEndsAt, d <= Date() {
            sleepFire()
        }
    }

    private func sleepFire() {
        sleepEndsAt = nil
        sleepAtEnd = false
        _ = apply(.pause)
        flash("Sleep timer ended")
    }

    private func start(_ item: VideoItem, pushPrevious: Bool = true) {
        if sleepAtEnd {
            sleepAtEnd = false
            sleepEndsAt = nil
        }
        if pushPrevious, let c = current { pushHistory(c) }
        current = item
        position = 0
        duration = item.duration ?? 0
        isPlaying = true
        js("load('\(item.videoID)')")
    }

    private func startIfIdle() {
        if current == nil { advance() }
    }

    /// Next in queue, or stop and go idle when the queue is empty.
    private func advance() {
        if queue.isEmpty {
            if let c = current { pushHistory(c) }
            current = nil
            isPlaying = false
            position = 0
            duration = 0
            js("player&&player.stopVideo&&player.stopVideo()")
        } else {
            start(queue.removeFirst())
        }
    }

    private func previous() {
        guard position <= 3, !history.isEmpty else { return seek(0) }
        let h = history.removeFirst()
        if let c = current { queue.insert(c, at: 0) }
        start(h, pushPrevious: false)
    }

    private func seek(_ t: Double) {
        let clamped = max(0, duration > 0 ? min(t, duration) : t)
        position = clamped
        js("player&&player.seekTo&&player.seekTo(\(clamped),true)")
    }

    private func pushHistory(_ item: VideoItem) {
        history.removeAll { $0.videoID == item.videoID }
        history = Array(([item] + history).prefix(50))
    }

    private func setSystemVolume(_ v: Float) {
        let c = min(max(v, 0), 1)
        volume = c
        // iOS web views cannot change volume themselves; drive the system volume instead.
        if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.setValue(c, animated: false)
            slider.sendActions(for: .touchUpInside)
        }
    }

    // MARK: Player bridge

    private func js(_ s: String) {
        if jsReady { webView.evaluateJavaScript(s) } else { pendingJS.append(s) }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let t = b["t"] as? String else { return }
        switch t {
        case "page":
            jsReady = true
            pendingJS.forEach { webView.evaluateJavaScript($0) }
            pendingJS = []
        case "time":
            if let p = b["pos"] as? Double, p.isFinite { position = p }
            if let d = b["dur"] as? Double, d.isFinite, d > 0 {
                duration = d
                if current?.duration != d { current?.duration = d }
            }
        case "state":
            Log.add("player state \(b["s"] ?? "?")")
            switch b["s"] as? Int ?? -1 {
            case 1: isPlaying = true
            case 2: isPlaying = false
            case 0:
                isPlaying = false
                if sleepAtEnd { sleepFire() } else { advance() }
            default: break
            }
            broadcast()
        case "error":
            Log.add("player error code \(b["c"] ?? "?") for \(current?.videoID ?? "-")")
            // Typically a video whose owner disabled embedding.
            flash("Can't play \(current?.title ?? "video") here, skipping")
            advance()
            broadcast()
        default:
            break
        }
    }

    // MARK: State out

    private func snapshot() -> ViewerState {
        ViewerState(deviceName: settings.name, current: current, isPlaying: isPlaying,
                    position: position, duration: duration, volume: volume, muted: volume < 0.01,
                    queue: queue, history: history, sleepEndsAt: sleepEndsAt)
    }

    private func broadcast() {
        server.broadcast(snapshot())
        guard running else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = current.map { c -> [String: Any] in
            [MPMediaItemPropertyTitle: c.title, MPMediaItemPropertyArtist: c.channel,
             MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
             MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        }
    }

    private func flash(_ s: String) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
}
