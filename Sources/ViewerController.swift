import Combine
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
    @Published var pending: [PendingPeer] = []
    @Published var volume: Float = AVAudioSession.sharedInstance().outputVolume
    /// iOS refused Local Network access, so no remote can find this viewer.
    @Published var denied = false
    /// Fires when the person taps the video, to show or hide the on-screen controls.
    let tapped = PassthroughSubject<Void, Never>()

    let webView: WKWebView
    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    private let settings: AppSettings
    private let pairing: Pairing
    private let browser: Browser
    private let server = ViewerServer()
    private var timer: Timer?
    private var toastWork: DispatchWorkItem?
    private var volumeObs: NSKeyValueObservation?
    private var premuteVolume: Float = 0.5
    private var running = false
    private var interruptObs: NSObjectProtocol?
    private var wasPlaying = false
    /// True from asking for a video until its page reports in; the outgoing page's last events are ignored.
    private var loading = false
    // What the remote asked for; re-applied on every new video.
    private var wantSpeed = 1.0
    private var wantCaptions: Bool?
    private var wantQuality: String?
    // What the player reports back.
    private var speed = 1.0
    private var captions = false
    private var quality: String?
    private var qualities: [String] = []
    private var pairedObs: AnyCancellable?

    // Runs inside the real YouTube watch page. Playing the page itself (not an embed) keeps the YouTube
    // sign-in, so Premium applies and videos that forbid embedding still play.
    // It fills the screen with the player, starts it with sound, and reports time and state.
    private static let bridge = """
    (function(){
      if (location.host.indexOf('youtube.com') < 0 || location.pathname !== '/watch') return;
      var post = function(o){ webkit.messageHandlers.yt.postMessage(o) };
      var want = true, started = false, alive = false, failed = false, ticks = 0;
      var wr = 1, wc = null, wq = null, tc = 0, tq = 0;
      function mp(){ return document.getElementById('movie_player') }
      function cc(){ try { var t = mp().getOption('captions','track'); return !!(t && t.languageCode) } catch(e) { return false } }
      function setCC(on){ try { var p = mp(); p.loadModule('captions');
        if (on) { var l = p.getOption('captions','tracklist') || []; if (l.length) p.setOption('captions','track',l[0]) }
        else p.setOption('captions','track',{}) } catch(e) {} }
      var css = document.createElement('style');
      // Hide YouTube's top bar, then pin the player's wrappers over the whole screen. The wrappers are pinned
      // rather than the player itself because WebKit placed a pinned player below the top bar.
      css.textContent = 'ytm-mobile-topbar-renderer,ytm-pivot-bar-renderer,#header-bar{display:none!important}' +
        '#player-container-id,#player{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;transform:none!important;z-index:2147483647!important;background:#000!important}' +
        '#movie_player{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;background:#000!important}' +
        // YouTube sizes captions for a small phone player; scale them to the screen instead.
        '#movie_player .ytp-caption-segment{font-size:clamp(15px,2.4vw,30px)!important;line-height:1.35!important}' +
        // YouTube's own wrapper around the video has no height, so size both it and the video explicitly.
        '#movie_player .html5-video-container{position:absolute!important;inset:0!important;width:100%!important;height:100%!important}' +
        '#movie_player video{position:absolute!important;width:100vw!important;height:100vh!important;left:0!important;top:0!important;object-fit:contain!important}' +
        'html,body{overflow:hidden!important;background:#000!important}';
      document.documentElement.appendChild(css);
      function vid(){ return document.querySelector('#movie_player video') || document.querySelector('video') }
      function ad(){ return !!document.querySelector('.ad-showing,.ad-interrupting') }
      window.__tr = {
        play: function(){ want = true; var v = vid(); if (v) v.play() },
        pause: function(){ want = false; var v = vid(); if (v) v.pause() },
        seek: function(t){ var v = vid(); if (v) v.currentTime = t },
        set: function(o){
          if (!o.q && wq) { try { mp().setPlaybackQualityRange('tiny','highres') } catch(e) {} }
          wr = o.rate; wc = o.cc; wq = o.q; tc = 0; tq = 0 }
      };
      document.addEventListener('playing', function(e){
        if (e.target.tagName !== 'VIDEO') return;
        alive = true;
        if (ad()) return;
        if (!started) { started = true; if (!want) { e.target.pause(); return } }
        post({t:'state', s:1});
      }, true);
      document.addEventListener('pause', function(e){
        if (e.target.tagName === 'VIDEO' && started && !e.target.ended && !ad()) post({t:'state', s:2});
      }, true);
      document.addEventListener('ended', function(e){
        if (e.target.tagName === 'VIDEO' && !ad()) post({t:'state', s:0});
      }, true);
      document.addEventListener('click', function(){ post({t:'tap'}) }, true);
      setInterval(function(){
        var v = vid(); ticks++;
        if (v) {
          var u = document.querySelector('.ytp-unmute'); if (u && u.offsetParent) u.click();
          if (v.muted) v.muted = false;
          if (!started && want && v.paused) v.play();
          if (!ad()) {
            var p = mp(), q = null, qs = [];
            if (started) {
              if (v.playbackRate !== wr) v.playbackRate = wr;
              if (wc !== null && cc() !== wc && tc++ < 20) setCC(wc);
              try { if (wq && p.getPlaybackQuality() !== wq && tq++ < 20) p.setPlaybackQualityRange(wq, wq) } catch(e) {}
            }
            try { q = p.getPlaybackQuality(); qs = p.getAvailableQualityLevels() } catch(e) {}
            post({t:'time', pos:v.currentTime, dur:v.duration, rate:v.playbackRate, cc:cc(), q:q, qs:qs});
          }
        }
        if (!alive && !failed && ticks > 40) { failed = true; post({t:'error'}) }
      }, 500);
      post({t:'page'});
    })()
    """

    init(settings: AppSettings, pairing: Pairing, browser: Browser) {
        self.settings = settings
        self.pairing = pairing
        self.browser = browser
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Same Safari-like UA as the browser, so the shared YouTube sign-in is accepted here too.
        cfg.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        // iPad asks for desktop sites by default; the bridge is written for the mobile watch page.
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
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
        server.onPair = { [weak self] m, id, reply in self?.pairing.receive(m, from: id, send: reply) }
        server.onPeers = { [weak self] in self?.pending = self?.server.pending ?? [] }
        server.onGone = { [weak self] id in self?.pairing.cancel(peer: id) }
        server.onDenied = { [weak self] in self?.denied = $0 }
        pairing.onPaired = { [weak self] d in self?.server.challenge(key: d.key) }
        // Removing a device in Settings disconnects it at once.
        pairedObs = settings.$paired.dropFirst().sink { [weak self] list in self?.server.keep(Set(list.map(\.key))) }
        server.start(name: settings.name, key: settings.deviceKey)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.broadcast() }
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
        pairedObs = nil
        pairing.cancel()
        timer?.invalidate()
        volumeObs = nil
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        interruptObs = nil
        let rc = MPRemoteCommandCenter.shared()
        [rc.playCommand, rc.pauseCommand, rc.nextTrackCommand, rc.previousTrackCommand,
         rc.changePlaybackPositionCommand].forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.isIdleTimerDisabled = false
        js("__tr.pause()")
        isPlaying = false
    }

    func beginPair(_ p: PendingPeer) {
        pairing.begin(peer: p.id) { [weak self] in self?.server.send(.pair($0), to: p.id) }
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
            return "Playing"
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
            js("__tr.pause()")
            return "Paused"
        case .resume:
            isPlaying = true
            js("__tr.play()")
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
        case .setSpeed(let r):
            wantSpeed = min(max(r, 0.25), 2)
            speed = wantSpeed
            pushSettings()
            return nil
        case .setCaptions(let on):
            wantCaptions = on
            captions = on
            pushSettings()
            return on ? "Captions on" : "Captions off"
        case .setQuality(let q):
            // The name is put into script on the page and arrives over the network: whitelist it.
            guard q.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil else { return nil }
            wantQuality = q == "auto" ? nil : q
            pushSettings()
            return nil
        }
    }

    // MARK: Playback

    private func start(_ item: VideoItem, pushPrevious: Bool = true) {
        if pushPrevious, let c = current { pushHistory(c) }
        current = item
        position = 0
        duration = item.duration ?? 0
        isPlaying = true
        loading = true
        // Saved sign-in cookies must be back in place before the page loads, or it loads signed out.
        browser.restoreCookies { [weak self] in
            guard let self, self.current?.id == item.id else { return }
            self.webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(item.videoID)")!))
        }
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
            webView.loadHTMLString("<body style='background:#000'>", baseURL: nil)
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
        js("__tr.seek(\(clamped))")
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

    private func pushSettings() {
        let cc = wantCaptions.map { "\($0)" } ?? "null"
        let q = wantQuality.map { "'\($0)'" } ?? "null"
        js("__tr.set({rate:\(wantSpeed),cc:\(cc),q:\(q)})")
    }

    /// `__tr` only exists on a watch page; calls made on any other page do nothing.
    private func js(_ s: String) {
        webView.evaluateJavaScript("window.__tr&&\(s)")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let t = b["t"] as? String else { return }
        switch t {
        case "page":
            loading = false
            // A pause that arrived while the page was still loading must hold once it starts.
            if !isPlaying { js("__tr.pause()") }
            pushSettings()
        case "tap":
            tapped.send()
        case _ where loading:
            break
        case "time":
            if let p = b["pos"] as? Double, p.isFinite { position = p }
            if let d = b["dur"] as? Double, d.isFinite, d > 0 {
                duration = d
                if current?.duration != d { current?.duration = d }
            }
            if let r = b["rate"] as? Double { speed = r }
            if let c = b["cc"] as? Bool { captions = c }
            quality = b["q"] as? String
            qualities = (b["qs"] as? [String] ?? []).filter { $0 != "auto" }
        case "state":
            Log.add("player state \(b["s"] ?? "?")")
            switch b["s"] as? Int ?? -1 {
            case 1: isPlaying = true
            case 2: isPlaying = false
            case 0:
                // An advert finishing also reports "ended"; only the video's own end moves the queue on.
                guard duration <= 0 || position >= duration - 3 else { break }
                isPlaying = false
                advance()
            default: break
            }
            broadcast()
        case "error":
            Log.add("player never started for \(current?.videoID ?? "-")")
            // Private, removed or region-blocked, or YouTube is asking for something on this screen.
            guard current != nil else { break }
            flash("Can't play \(current?.title ?? "video") here, skipping")
            advance()
            broadcast()
        default:
            break
        }
    }

    // MARK: State out

    func snapshot() -> ViewerState {
        ViewerState(deviceName: settings.name, current: current, isPlaying: isPlaying,
                    position: position, duration: duration, volume: volume, queue: queue, history: history,
                    speed: speed, captions: captions, quality: quality, qualities: qualities)
    }

    private func broadcast() {
        // The volume-change notification is not reliable while a web view owns the audio, so also read
        // the system slider each time; it follows the hardware buttons.
        if let v = volumeView.subviews.compactMap({ $0 as? UISlider }).first?.value, abs(v - volume) > 0.005 {
            volume = v
        }
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
