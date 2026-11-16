import Combine
import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer

/// Owns the queue, history and player. Remotes only send commands; this is the single source of truth.
final class ViewerController: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var current: VideoItem?
    @Published var isPlaying = false
    // Not published: they change twice a second, and publishing re-drew the whole viewer screen each time,
    // which made its menu flicker. The overlay's slider reads them on its own timer.
    var position = 0.0
    var duration = 0.0
    @Published var queue: [VideoItem] = []
    @Published var history: [VideoItem] = []
    @Published var toast: String?
    @Published var pending: [PendingPeer] = []
    @Published var connected: [PendingPeer] = []
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
    @Published private(set) var wantCaptions: Bool?
    /// The video has no captions to show.
    @Published private(set) var captionsNone = false
    /// "searching" while captions are wanted but not showing yet, "none" when the video has none, else nil.
    var captionsStatus: String? {
        if captionsNone { return "none" }
        return wantCaptions == true && !captions ? "searching" : nil
    }
    private var wantQuality: String?
    // What the player reports back.
    @Published private(set) var speed = 1.0
    // Published so the viewer's own overlay shows them; remotes get the same values in the snapshot.
    @Published private(set) var captions = false
    @Published private(set) var quality: String?
    @Published private(set) var qualities: [String] = []
    /// No quality is forced; `quality` is then whatever YouTube picked.
    @Published private(set) var autoQuality = true
    /// When the sleep timer will pause playback. Only set when it changes, so the screen is not redrawn each second.
    @Published private(set) var sleepEndsAt: Date?
    private var sleepAtEnd = false
    private var adSkippable = false
    /// What was last asked for, as opposed to `isPlaying`, which is what the page reports.
    private var wantPlaying = false
    /// When the current video first reported playing; nil until it has.
    private var firstPlay: Date?
    private var lastKick = Date.distantPast
    // Start-up nudging watches the playback position, which is the one thing that cannot be wrong.
    private var startedAt = Date()
    private var lastPos = -1.0
    private var lastMove = Date()
    private var kickCount = 0
    private var unmuteTries = 0
    /// The video is still muted after the automatic attempts, so the overlay offers a button.
    @Published private(set) var needsUnmute = false
    private var pairedObs: AnyCancellable?

    // Runs inside the real YouTube watch page. Playing the page itself (not an embed) keeps the YouTube
    // sign-in, so Premium applies and videos that forbid embedding still play.
    // It fills the screen with the player, starts it with sound, and reports time and state.
    private static let bridge = """
    (function(){
      if (location.host.indexOf('youtube.com') < 0 || location.pathname !== '/watch') return;
      var post = function(o){ webkit.messageHandlers.yt.postMessage(o) };
      var want = true, started = false, alive = false, failed = false, ticks = 0;
      var wr = 1, wc = null, wq = null, tc = 0, tq = 0, errored = false;
      function mp(){ return document.getElementById('movie_player') }
      function cc(){
        try { return !!mp().isSubtitlesOn() } catch(e) {}
        try { var t = mp().getOption('captions','track'); return !!(t && t.languageCode) } catch(e) { return false } }
      // The caption list loads some time after the module is asked for, and asking again restarts the load,
      // so the module is requested once and later calls only look for the list.
      function pick(l){
        var lang = (navigator.language || 'en').slice(0,2), best = null;
        for (var i = 0; i < l.length; i++) {
          if ((l[i].languageCode || '').slice(0,2) !== lang) continue;
          if (l[i].kind !== 'asr') return l[i];
          best = best || l[i];
        }
        return best || l[0] }
      function setCC(on, first){ try { var p = mp();
        if (first) p.loadModule('captions');
        if (on) {
          var l = p.getOption('captions','tracklist') || [];
          if (l.length) p.setOption('captions','track',pick(l)); else if (!first) p.toggleSubtitlesOn()
        } else {
          p.setOption('captions','track',{});
          if (cc()) p.toggleSubtitles()
        } } catch(e) {} }
      var css = document.createElement('style');
      // Hide YouTube's top bar, then pin the player's wrappers over the whole screen. The wrappers are pinned
      // rather than the player itself because WebKit placed a pinned player below the top bar.
      css.textContent = 'ytm-mobile-topbar-renderer,ytm-pivot-bar-renderer,#header-bar{display:none!important}' +
        // YouTube's own "tap to unmute" button cannot be used here, because taps on the video are taken over by the app.
        '.ytp-unmute{display:none!important}' +
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
      // The quality to hold, resolved for this video: "best" is the top one offered below 8K, and a fixed one
      // that this video lacks becomes the nearest one below it.
      function target(){
        if (!wq) return null;
        try {
          var l = mp().getAvailableQualityLevels().filter(function(x){ return x !== 'auto' && x !== 'highres' });
          if (!l.length) return null;
          if (wq === 'best') return l[0];
          if (l.indexOf(wq) >= 0) return wq;
          var order = ['hd2160','hd1440','hd1080','hd720','large','medium','small','tiny'];
          for (var k = Math.max(order.indexOf(wq), 0); k < order.length; k++) if (l.indexOf(order[k]) >= 0) return order[k];
          return l[l.length - 1];
        } catch(e) { return wq }
      }
      // YouTube has renamed its Skip button more than once; try each known name.
      function skipButton(){
        var b = document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button-modern,.ytp-ad-skip-button,.ytp-ad-skip-button-container button');
        return b && b.offsetParent ? b : null }
      window.__tr = {
        play: function(){ want = true; var v = vid(); if (v) v.play() },
        pause: function(){ want = false; var v = vid(); if (v) v.pause() },
        seek: function(t){ var v = vid(); if (v) v.currentTime = t },
        skipAd: function(){ var b = skipButton(); if (b) b.click() },
        // Nudge a video that is not moving. Each attempt tries a different way to start it, and says which in the
        // debug log. Called from the app, so it runs as the same kind of call as a tap on Play.
        kick: function(n){
          var v = vid(), p = mp(); if (!v) return;
          var log = function(m){ post({t:'log', m:'kick ' + n + ': ' + m}) };
          try {
            if (n === 0) {
              var r = v.play();
              if (r && r.then) r.then(function(){ log('play() ok') }, function(e){ log('play() rejected ' + e.name) });
            } else if (n === 1) { p.playVideo(); log('playVideo()') }
            else { p.unMute(); p.playVideo(); log('unMute() and playVideo()') }
          } catch(e) { log('error ' + e) }
        },
        // Unmute through the player, which is what its own unmute button does.
        unmute: function(){
          var p = mp(), v = vid();
          try { p.unMute() } catch(e) {}
          if (v && v.muted) v.muted = false;
          post({t:'log', m:'unmute requested'});
        },
        // Asks for Picture in Picture the way any web page may. YouTube decides whether to allow it
        // (it does for Premium accounts); nothing here overrides a refusal.
        pip: function(){
          var v = vid(); if (!v) return;
          var on = function(){ return v.webkitPresentationMode === 'picture-in-picture' || document.pictureInPictureElement === v };
          var was = on();
          try {
            if (typeof v.webkitSetPresentationMode === 'function') v.webkitSetPresentationMode(was ? 'inline' : 'picture-in-picture');
            else if (was) document.exitPictureInPicture();
            else v.requestPictureInPicture();
          } catch(e) {}
          if (!was) setTimeout(function(){ if (!on()) post({t:'nopip'}) }, 1500);
        },
        set: function(o){
          // Back to automatic: lift the limit and forget the choice YouTube saved for later videos.
          if (!o.q && wq) {
            try { localStorage.removeItem('yt-player-quality') } catch(e) {}
            try { mp().setPlaybackQualityRange('auto','auto') } catch(e) {}
          }
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
      // YouTube's player pauses or resumes on any tap. Keep taps away from it and show our own controls
      // instead. During an advert taps go through untouched, so Skip Ad still works.
      var lastTap = 0;
      ['touchstart','touchend','pointerdown','pointerup','mousedown','mouseup','click','dblclick'].forEach(function(n){
        document.addEventListener(n, function(e){
          // Only real finger taps. This script's own clicks (unmute, Skip Ad) must reach YouTube
          // and must not count as taps.
          if (!e.isTrusted || ad()) return;
          e.stopImmediatePropagation();
          if (n === 'touchend' && e.cancelable) e.preventDefault();
          if ((n === 'touchend' || n === 'click') && Date.now() - lastTap > 400) { lastTap = Date.now(); post({t:'tap'}) }
        }, {capture: true, passive: false});
      });
      setInterval(function(){
        var v = vid(); ticks++;
        // YouTube's own error screen ("An error occurred", "Video unavailable"). A forced quality the device
        // cannot decode ends here, so forget it and let the app reload on Auto.
        var er = document.querySelector('.ytp-error');
        if (er && er.offsetParent && !errored) {
          errored = true;
          if (wq) { try { localStorage.removeItem('yt-player-quality') } catch(e) {} }
          post({t:'perr', forced: !!wq});
        }
        post({t:'ad', skip: ad() && !!skipButton()});
        if (v) {
          if (!started && want && v.paused) v.play();
          if (!ad()) {
            var p = mp(), q = null, qs = [];
            if (started) {
              if (v.playbackRate !== wr) v.playbackRate = wr;
              // Twelve seconds of trying; after that the video has no captions to show.
              if (wc !== null && cc() !== wc && tc < 24) { setCC(wc, tc === 0); tc++; if (tc === 24 && wc) post({t:'nocc'}) }
              try { var t = target(); if (t && p.getPlaybackQuality() !== t && tq++ < 20) p.setPlaybackQualityRange(t, t) } catch(e) {}
            }
            try { q = p.getPlaybackQuality(); qs = p.getAvailableQualityLevels() } catch(e) {}
            post({t:'time', pos:v.currentTime, dur:v.duration, rate:v.playbackRate, cc:cc(), q:q, qs:qs,
                  paused:v.paused, muted:v.muted});
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
        cfg.applicationNameForUserAgent = WebIdentity.applicationName
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
        server.onPeers = { [weak self] in
            self?.pending = self?.server.pending ?? []
            self?.connected = self?.server.connected ?? []
        }
        server.onGone = { [weak self] id in self?.pairing.cancel(peer: id) }
        server.onDenied = { [weak self] in self?.denied = $0 }
        server.viewerPro = { ProStore.shared.isPro }
        server.notify = { [weak self] in self?.flash($0) }
        pairing.onPaired = { [weak self] d in self?.server.challenge(key: d.key) }
        // Removing a device in Settings disconnects it at once.
        pairedObs = settings.$paired.dropFirst().sink { [weak self] list in self?.server.keep(Set(list.map(\.key))) }
        server.start(name: settings.name, key: settings.deviceKey)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickSleep()
            self?.broadcast()
        }
        interruptObs = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Log.add("audio interruption \(type == .began ? "began" : "ended")")
            if type == .began {
                // Unmuting a video makes iOS report an interruption to this app's own audio session, though
                // nothing else is playing. Pausing for it is what stopped every first video, so it is ignored
                // while a video is starting or has just been unmuted. A real one (a call, Siri) comes later.
                if Date().timeIntervalSince(self.startedAt) < 8 || Date().timeIntervalSince(self.lastKick) < 3 {
                    return Log.add("ignored: it came with the video starting or unmuting")
                }
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
        sleepEndsAt = nil
        sleepAtEnd = false
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
        wantPlaying = false
    }

    func disconnect(_ p: PendingPeer) { server.disconnect(p.id) }

    /// Ends the session in one step: stops playback, empties the queue and disconnects every remote, which
    /// leaves the viewer on its ready screen. Pairings and history stay.
    func endSession() {
        Log.add("session ended")
        sleepEndsAt = nil
        sleepAtEnd = false
        queue = []
        advance()
        wantPlaying = false
        server.disconnectAll()
    }

    /// Called from a real tap on the overlay's button, which is the one kind of call that always unmutes.
    func unmuteVideo() {
        lastKick = Date()
        js("__tr.unmute()")
    }

    func beginPair(_ p: PendingPeer) {
        pairing.begin(peer: p.id) { [weak self] in self?.server.send(.pair($0), to: p.id) }
    }

    /// Moves the video into, or back out of, a floating Picture in Picture window.
    func togglePictureInPicture() { js("__tr.pip()") }

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
            Log.add("pause applied")
            isPlaying = false
            wantPlaying = false
            js("__tr.pause()")
            return "Paused"
        case .resume:
            isPlaying = true
            wantPlaying = true
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
        case .setPreferredQuality(let q):
            // Also arrives over the network and is put into script on the page, so only known values.
            guard preferredQualityChoices.contains(where: { $0.id == q }) else { return nil }
            settings.preferredQuality = q
            wantQuality = q == "auto" ? nil : q
            autoQuality = wantQuality == nil
            pushSettings()
            return nil
        case .setSleepTimer(let s):
            sleepAtEnd = false
            guard let s, s.isFinite, s >= 0 else {
                sleepEndsAt = nil
                return "Sleep timer off"
            }
            if s == 0 {
                guard current != nil else { return nil }
                sleepAtEnd = true
                sleepEndsAt = Date().addingTimeInterval(max(duration - position, 0))
            } else {
                sleepEndsAt = Date().addingTimeInterval(min(s, 12 * 3600))
            }
            return "Sleep timer set"
        case .playlist(let items, let action):
            // Arrives over the network: only valid ids, and not more than a playlist page holds.
            let list = items.filter(\.isValid).prefix(200).map(\.fresh)
            guard let first = list.first else { return nil }
            switch action {
            case .playNow:
                start(first, pushPrevious: current?.videoID != first.videoID)
                queue.insert(contentsOf: list.dropFirst(), at: 0)
            case .playNext:
                queue.insert(contentsOf: list, at: 0)
                startIfIdle()
            case .addToEnd:
                queue.append(contentsOf: list)
                startIfIdle()
            }
            return "Playlist queued: \(list.count) videos"
        case .skipAd:
            js("__tr.skipAd()")
            return "Skipped ad"
        case .setSpeed(let r):
            wantSpeed = min(max(r, 0.25), 2)
            speed = wantSpeed
            pushSettings()
            return nil
        case .setCaptions(let on):
            // No message here: it would claim success before the player has done anything. The state
            // reports "searching", then captions on, or "none" if the video has no captions.
            wantCaptions = on
            captionsNone = false
            if !on { captions = false }
            pushSettings()
            return nil
        case .setQuality(let q):
            // The name is put into script on the page and arrives over the network: whitelist it.
            guard q.range(of: "^[a-z0-9]{1,12}$", options: .regularExpression) != nil else { return nil }
            wantQuality = q == "auto" ? nil : q
            autoQuality = wantQuality == nil
            pushSettings()
            return nil
        }
    }

    // MARK: Playback

    private func tickSleep() {
        if sleepAtEnd {
            let end = Date().addingTimeInterval(max(duration - position, 0))
            // The estimate barely moves while playing; only publish a real change.
            if let e = sleepEndsAt, abs(e.timeIntervalSince(end)) < 3 { return }
            sleepEndsAt = end
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
        if pushPrevious, let c = current { pushHistory(c) }
        current = item
        position = 0
        duration = item.duration ?? 0
        // An "end of video" timer belongs to the video it was set on.
        if sleepAtEnd {
            sleepAtEnd = false
            sleepEndsAt = nil
        }
        isPlaying = true
        wantPlaying = true
        firstPlay = nil
        startedAt = Date()
        lastPos = -1
        lastMove = Date()
        kickCount = 0
        unmuteTries = 0
        needsUnmute = false
        loading = true
        adSkippable = false
        captionsNone = false
        // A quality picked by hand lasts for one video; the next starts at the preferred quality.
        wantQuality = settings.preferredQuality == "auto" ? nil : settings.preferredQuality
        autoQuality = wantQuality == nil
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
        case "perr":
            guard let id = current?.videoID else { break }
            if b["forced"] as? Bool == true {
                Log.add("player error with quality forced, back to Auto")
                wantQuality = nil
                autoQuality = true
                flash("That quality will not play on this device. Back to Auto.")
                loading = true
                webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(id)&t=\(Int(position))s")!))
            } else {
                Log.add("player error screen")
                flash("Can't play \(current?.title ?? "video") here, skipping")
                advance()
            }
            broadcast()
        case "log":
            Log.add("page: \(b["m"] as? String ?? "?")")
        case "nocc":
            captions = false
            captionsNone = true
            flash("This video has no captions")
            broadcast()
        case "nopip":
            flash("Picture in Picture is not available. YouTube allows it with Premium.")
        case _ where loading:
            break
        case "ad":
            let skip = b["skip"] as? Bool ?? false
            if skip != adSkippable {
                adSkippable = skip
                broadcast()
            }
        case "time":
            if let p = b["pos"] as? Double, p.isFinite { position = p }
            if let d = b["dur"] as? Double, d.isFinite, d > 0 {
                duration = d
                if current?.duration != d { current?.duration = d }
            }
            if let r = b["rate"] as? Double, r != speed { speed = r }
            // Published values are only set when they change, so a steady player causes no redraw.
            if let c = b["cc"] as? Bool, c != captions { captions = c }
            // YouTube starts the first video of a session muted, and it can stall while starting. Judge by the
            // playback position: if it has not moved for over a second in the first 25 seconds, try the next
            // way of starting it. Once it is moving, unmute it if it is still muted.
            let now = Date()
            if let p = b["pos"] as? Double, abs(p - lastPos) > 0.05 { lastPos = p; lastMove = now }
            let notMoving = now.timeIntervalSince(lastMove) > 1.2
            if wantPlaying, notMoving, now.timeIntervalSince(startedAt) < 25, now.timeIntervalSince(lastKick) > 1.2 {
                lastKick = now
                Log.add("not moving at \(lastPos) paused=\(b["paused"] ?? "?") muted=\(b["muted"] ?? "?"), attempt \(kickCount % 3)")
                js("__tr.kick(\(kickCount % 3))")
                kickCount += 1
            } else if wantPlaying, !notMoving, b["muted"] as? Bool == true, now.timeIntervalSince(lastKick) > 1 {
                // Each attempt can pause the video, so only a few; after that the person gets a button.
                if unmuteTries < 3 {
                    unmuteTries += 1
                    lastKick = now
                    js("__tr.unmute()")
                } else if !needsUnmute {
                    needsUnmute = true
                }
            }
            if needsUnmute, b["muted"] as? Bool != true { needsUnmute = false }
            let q = b["q"] as? String
            if q != quality { quality = q }
            // "highres" is 8K, which no iPad decodes; forcing it ends in a playback error. 4K plays.
            let qs = (b["qs"] as? [String] ?? []).filter { $0 != "auto" && $0 != "highres" }
            if qs != qualities { qualities = qs }
        case "state":
            Log.add("player state \(b["s"] ?? "?")")
            switch b["s"] as? Int ?? -1 {
            case 1:
                isPlaying = true
                if firstPlay == nil { firstPlay = Date() }
            case 2:
                // A pause in the first seconds is the start-up stall handled above, not a real pause.
                if wantPlaying, firstPlay.map({ Date().timeIntervalSince($0) < 8 }) ?? true { break }
                isPlaying = false
                wantPlaying = false
            case 0:
                // An advert finishing also reports "ended"; only the video's own end moves the queue on.
                guard duration <= 0 || position >= duration - 3 else { break }
                isPlaying = false
                if sleepAtEnd { sleepFire() } else { advance() }
            default: break
            }
            broadcast()
        case "error":
            Log.add("player never started")
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
                    speed: speed, captions: captions, quality: quality, qualities: qualities,
                    adSkippable: adSkippable, preferredQuality: settings.preferredQuality, sleepEndsAt: sleepEndsAt,
                    autoQuality: autoQuality, captionsStatus: captionsStatus)
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
