import Combine
import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer

final class ViewerController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var current: VideoItem?
    @Published var isPlaying = false
    // Not published: they change twice a second, and publishing re-drew the whole viewer screen each time,
    // which made its menu flicker. The overlay's slider reads them on its own timer.
    var position = 0.0
    var duration = 0.0
    @Published var queue: [VideoItem] = []
    @Published var history: [VideoItem] = [] {
        didSet { Store.write("history.json", try? JSONEncoder().encode(history)) }
    }
    @Published var toast: String?
    @Published var pending: [PendingPeer] = []
    @Published var connected: [PendingPeer] = []
    @Published var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @Published var denied = false
    let tapped = PassthroughSubject<Void, Never>()

    let webView: WKWebView
    let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    private let settings: AppSettings
    var autoplay: Bool { settings.autoplay }
    private let pairing: Pairing
    private let browser: Browser
    private let server = ViewerServer()
    var sessionPro: Bool { ProStore.shared.isPro || server.anyRemotePro }
    private var timer: Timer?
    private var toastWork: DispatchWorkItem?
    private var toastShared = false
    private var volumeObs: NSKeyValueObservation?
    private var premuteVolume: Float = 0.5
    private var brightnessBeforeSleep: CGFloat?
    private var lastBrightnessSet: (value: CGFloat, at: Date)?
    private var lastBrightnessLog = Date.distantPast
    private var activeObs: NSObjectProtocol?
    private var brightnessObs: NSObjectProtocol?
    private var screen: UIScreen? { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first }
    private var running = false
    private var interruptObs: NSObjectProtocol?
    private var wasPlaying = false
    /// True from asking for a video until its page reports in; the outgoing page's last events are ignored.
    private var loading = false
    private var wantSpeed = 1.0
    @Published private(set) var wantCaptions: Bool?
    @Published private(set) var captionsNone = false
    var captionsStatus: String? {
        if captionsNone { return "none" }
        return wantCaptions == true && !captions ? "searching" : nil
    }
    private var wantQuality: String?
    @Published private(set) var speed = 1.0
    @Published private(set) var captions = false
    @Published private(set) var quality: String?
    @Published private(set) var qualities: [String] = []
    @Published private(set) var autoQuality = true
    @Published private(set) var sleepEndsAt: Date?
    private var sleepAtEnd = false
    private var sleepAtQueueEnd = false
    private var awaitingNext = false
    @Published private(set) var autoplayNext: VideoItem?
    @Published private(set) var richView = false
    @Published private(set) var richTab = 0
    @Published private(set) var richScroll = 0
    @Published private(set) var richPosition: Int?
    @Published private(set) var details: VideoDetails?
    private var watching = false
    private var infoTries = 0
    var live = false
    private var liveReloaded = false
    private var scanDir = 0
    private var scanMuted = false
    private var scanStart = 0.0
    private var scanStartedAt = Date()
    private var scanTick = Date()
    private var scanCap = ScanRamp.base
    private var scanTimer: Timer?
    private var scanSeen = Date.distantPast
    private var scanWasPlaying = false
    var atLiveHead = false
    private var commentsNext: String?
    private var replyTokens: [String: String] = [:]
    private var replyLoading = Set<String>()
    private var commentsLoading = false
    private var needsDetails: Bool { watching || richView }
    private var candidateFor: UUID?
    private var skipExtra: [String] = []
    private var autoplayStreak = 0
    static let maxAutoplay = 50
    private var adSkippable = false
    private var wantPlaying = false
    private var firstPlay: Date?
    private var lastKick = Date.distantPast
    // Start-up nudging watches the playback position, which is the one thing that cannot be wrong.
    private var startedAt = Date()
    private var lastPos = -1.0
    private var lastMove = Date()
    private var kickCount = 0
    /// Just after a seek the page may still report the old time; it is not passed on until then.
    private var seekHoldUntil = Date.distantPast
    private var unmuteTries = 0
    @Published private(set) var needsUnmute = false
    private var pairedObs: AnyCancellable?

    // Runs inside the real YouTube watch page. Playing the page itself (not an embed) keeps the YouTube
    // sign-in, so Premium applies and videos that forbid embedding still play.
    static let maxQueue = 1000
    static let maxComments = 200
    static let maxScanRate = 8.0

    private static let bridge = """
    (function(){
      if (location.host.indexOf('youtube.com') < 0 || location.pathname !== '/watch') return;
      var post = function(o){ webkit.messageHandlers.yt.postMessage(o) };
      var want = true, started = false, alive = false, failed = false, ticks = 0;
      var wr = 1, sr = 0, pm = null, wc = null, wq = null, tc = 0, tq = 0, errored = false;
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
      function ytPage(tok, done, fail){
        var cfg = function(k){ try { return ytcfg.get(k) } catch(e) { return null } };
        var text = function(x){ return x ? (x.simpleText || (x.runs || []).map(function(r){ return r.text }).join('')) : '' };
        var key = cfg('INNERTUBE_API_KEY');
        fetch('/youtubei/v1/next?prettyPrint=false' + (key ? '&key=' + key : ''), {
          method: 'POST', credentials: 'include', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({context: cfg('INNERTUBE_CONTEXT'), continuation: tok})
        }).then(function(r){ return r.json() }).then(function(j){
          var ents = {};
          var muts = ((j.frameworkUpdates || {}).entityBatchUpdate || {}).mutations || [];
          muts.forEach(function(m){ var p = m.payload && m.payload.commentEntityPayload; if (p) ents[m.entityKey || p.key] = p });
          var replyTok = function(t){
            if (!t.replies) return '';
            try {
              var st = [t.replies], n = 0;
              while (st.length && n++ < 2000) {
                var x = st.pop();
                if (x && typeof x === 'object') {
                  if (x.continuationCommand && x.continuationCommand.token) return x.continuationCommand.token;
                  for (var k in x) st.push(x[k]);
                }
              }
            } catch(e) {}
            if (!window.__noRepTok) { window.__noRepTok = true; post({t:'log', m:'no reply token in ' + JSON.stringify(t.replies).slice(0, 400)}) }
            return '';
          };
          var fromVM = function(vm, rt, i){
            var v = vm.commentViewModel || vm, p = ents[v.commentKey];
            if (!p) return null;
            var pr = p.properties || {}, tb = p.toolbar || {};
            return {id: pr.commentId || v.commentId || String(i), a: (p.author || {}).displayName || '', t: (pr.content || {}).content || '',
                    l: tb.likeCountNotliked || tb.likeCountLiked || '', w: pr.publishedTime || '', r: tb.replyCount || '', rt: rt};
          };
          var fromCR = function(cr, rt, i){
            return {id: cr.commentId || String(i), a: text(cr.authorText), t: text(cr.contentText), l: text(cr.voteCount),
                    w: text(cr.publishedTimeText), r: cr.replyCount ? String(cr.replyCount) : '', rt: rt};
          };
          var one = function(it, i){
            var t = it.commentThreadRenderer;
            if (t) {
              if (t.commentViewModel) return fromVM(t.commentViewModel, replyTok(t), i);
              if (t.comment && t.comment.commentRenderer) return fromCR(t.comment.commentRenderer, replyTok(t), i);
              return null;
            }
            if (it.commentViewModel) return fromVM(it.commentViewModel, '', i);
            if (it.commentRenderer) return fromCR(it.commentRenderer, '', i);
            return null;
          };
          var items = [], next = null;
          (j.onResponseReceivedEndpoints || j.onResponseReceivedActions || []).forEach(function(e){
            var c = e.reloadContinuationItemsCommand || e.appendContinuationItemsAction || {};
            (c.continuationItems || []).forEach(function(it){
              var x = one(it, items.length);
              if (x) items.push(x);
              var ci = it.continuationItemRenderer;
              if (ci) {
                var ep = ci.continuationEndpoint || (((ci.button || {}).buttonRenderer || {}).command) || {};
                if (ep.continuationCommand) next = ep.continuationCommand.token;
              }
            });
          });
          if (!items.length) {
            try {
              var e0 = (j.onResponseReceivedEndpoints || j.onResponseReceivedActions || [])[0] || {}, k0 = Object.keys(e0)[0] || '';
              var c0 = e0[k0] || {}, list0 = c0.continuationItems || [];
              post({t:'log', m:'ytPage empty: top ' + Object.keys(j).join(',') + '; action ' + k0 + '; ' + list0.length + ' items, first ' +
                    Object.keys(list0[0] || {}).join(',') + '; ' + muts.length + ' mutations'});
            } catch(x) {}
          }
          done(items, next, muts.length);
        }).catch(fail);
      }
      window.__tr = {
        play: function(){ want = true; var v = vid(); if (v) v.play() },
        pause: function(){ want = false; var v = vid(); if (v) v.pause() },
        // Through the player, which knows about a seek still in progress; writing currentTime behind its back
        // can be undone by it, and a second seek soon after the first was often lost.
        seek: function(t){
          try { var p = mp(); if (p && p.seekTo) { p.seekTo(t, true); return } } catch(e) {}
          var v = vid(); if (v) v.currentTime = t
        },
        // YouTube ignores a script's click on Skip, so send the whole press and, if the ad is still up, end it.
        skipAd: function(){
          var log = function(m){ post({t:'log', m:'skip ad: ' + m}) };
          var b = skipButton();
          if (!b) return log('no button found');
          var r = b.getBoundingClientRect(), v = vid();
          log('button ' + b.tagName + '.' + String(b.className).slice(0, 60) + ' at ' + Math.round(r.left) + ',' + Math.round(r.top) +
              ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ', ad video ' + (v ? Math.round(v.currentTime) + '/' + Math.round(v.duration) : 'none'));
          var o = {bubbles:true, cancelable:true, composed:true, view:window, clientX:r.left + r.width / 2, clientY:r.top + r.height / 2};
          var sent = [];
          ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(n){
            try { b.dispatchEvent(n.indexOf('pointer') === 0 ? new PointerEvent(n, o) : new MouseEvent(n, o)); sent.push(n) }
            catch(e) { log(n + ' failed: ' + e) }
          });
          log('sent ' + sent.join(','));
          setTimeout(function(){
            if (!ad()) return log('ad gone after the click');
            var tries = 0;
            var end = function(){
              if (!ad()) return log('ad gone');
              var v2 = vid();
              if (v2 && isFinite(v2.duration) && v2.duration > 1) {
                log('click ignored, moving the ad to its end (' + Math.round(v2.currentTime) + '/' + Math.round(v2.duration) + ', paused ' + v2.paused + ')');
                v2.currentTime = Math.max(v2.duration - 0.3, 0);
                var pr = v2.play(); if (pr && pr.catch) pr.catch(function(){});
                setTimeout(function(){ var v3 = vid(); log(ad() ? 'ad still showing 2 s after moving it, paused ' + (v3 && v3.paused) : 'ad gone after moving it') }, 2000);
                return;
              }
              if (tries++ < 8) setTimeout(end, 500); else log('gave up, the ad video has no length');
            };
            end();
          }, 400);
        },
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
        // The first page of the video's comments, or the page after `token`, through the same call the page makes
        // itself. YouTube changes this answer's shape from time to time, so both known shapes are read and what
        // came back is logged.
        comments: function(token){
          var log = function(m){ post({t:'log', m:'comments ' + m}) };
          var fail = function(s){ post({t:'comments', items:[], next:null, status:s}) };
          var walk = function(o, fn){
            var st = [o], n = 0;
            while (st.length && n++ < 300000) {
              var x = st.pop();
              if (x && typeof x === 'object') {
                if (fn(x)) return x;
                for (var k in x) st.push(x[k]);
              }
            }
            return null;
          };
          try {
            var tok = token;
            if (!tok) {
              var panel = walk(window.ytInitialData, function(x){
                return x.panelIdentifier === 'engagement-panel-comments-section' || x.sectionIdentifier === 'comment-item-section' });
              var holder = panel && walk(panel, function(x){ return x.continuationCommand && x.continuationCommand.token });
              tok = holder && holder.continuationCommand.token;
            }
            if (!tok) { log('no continuation token'); return fail('none') }
            ytPage(tok, function(items, next, muts){
              log(items.length + ' comments, next ' + !!next + ', mutations ' + muts);
              post({t:'comments', items:items, next:next, status: items.length || token ? 'ok' : 'none'});
            }, function(e){ log('fetch failed ' + e); fail('error') });
          } catch(e) { log('error ' + e); fail('error') }
        },
        replies: function(cid, token){
          var fail = function(e){ post({t:'log', m:'replies failed ' + e}); post({t:'replies', cid:cid, items:[], next:null}) };
          try {
            ytPage(token, function(items, next, muts){
              post({t:'log', m:'replies ' + items.length + ', next ' + !!next + ', mutations ' + muts});
              post({t:'replies', cid:cid, items:items, next:next});
            }, fail);
          } catch(e) { fail(e) }
        },
        scan: function(r){ sr = r; var v = vid(); if (v) v.playbackRate = r || wr },
        scanMute: function(on){
          var v = vid(); if (!v) return;
          if (on) { if (pm === null) pm = v.muted; v.muted = true }
          else if (pm !== null) { v.muted = pm; pm = null }
        },
        goLive: function(){
          try { mp().seekToLiveHead(); return } catch(e) {}
          var b = document.querySelector('.ytp-live-badge'); if (b) b.click();
        },
        info: function(){
          var r = window.ytInitialPlayerResponse || {}, d = r.videoDetails || {}, m = {};
          try { m = r.microformat.playerMicroformatRenderer || {} } catch(e) {}
          post({t:'info', id:d.videoId || null, title:d.title || '', channel:d.author || '', views:d.viewCount || '',
                date:m.publishDate || m.uploadDate || '', desc:d.shortDescription || '',
                sb:((r.storyboards || {}).playerStoryboardSpecRenderer || {}).spec || ''});
        },
        next: function(skip){
          var ok = function(x){ return typeof x === 'string' && x.length === 11 && skip.indexOf(x) < 0 };
          var id = null;
          try {
            var sets = window.ytInitialData.contents.singleColumnWatchNextResults.autoplay.autoplay.sets;
            for (var i = 0; i < sets.length && !id; i++) {
              var x = sets[i].autoplayVideo.watchEndpoint.videoId;
              if (ok(x)) id = x;
            }
          } catch(e) {}
          if (!id) {
            var as = document.querySelectorAll('a[href*="/watch?v="]');
            for (var j = 0; j < as.length && !id; j++) {
              var h = as[j].getAttribute('href') || '', k = h.indexOf('v=');
              var y = k < 0 ? '' : h.substr(k + 2, 11);
              if (ok(y)) id = y;
            }
          }
          post({t:'log', m:'autoplay candidate ' + id});
          post({t:'next', id:id});
        },
        set: function(o){
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
      var lastTouch = 0, lastTapAt = 0, tapTimer = null;
      var tapped = function(e){
        var t = (e.changedTouches && e.changedTouches[0]) || e;
        var side = t.clientX < innerWidth / 2 ? -1 : 1;
        var now = Date.now();
        if (tapTimer && now - lastTapAt < 350) {
          clearTimeout(tapTimer); tapTimer = null; lastTapAt = 0;
          post({t:'dtap', side:side});
          return;
        }
        lastTapAt = now;
        tapTimer = setTimeout(function(){ tapTimer = null; post({t:'tap'}) }, 320);
      };
      ['touchstart','touchend','pointerdown','pointerup','mousedown','mouseup','click','dblclick'].forEach(function(n){
        document.addEventListener(n, function(e){
          if (!e.isTrusted || ad()) return;
          e.stopImmediatePropagation();
          if (n === 'touchend' && e.cancelable) e.preventDefault();
          if (n === 'touchend') { lastTouch = Date.now(); tapped(e) }
          else if (n === 'click' && Date.now() - lastTouch > 500) tapped(e);
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
              if (v.playbackRate !== (sr || wr)) v.playbackRate = sr || wr;
              // Twelve seconds of trying; after that the video has no captions to show.
              if (wc !== null && cc() !== wc && tc < 24) { setCC(wc, tc === 0); tc++; if (tc === 24 && wc) post({t:'nocc'}) }
              try { var t = target(); if (t && p.getPlaybackQuality() !== t && tq++ < 20) p.setPlaybackQualityRange(t, t) } catch(e) {}
            }
            try { q = p.getPlaybackQuality(); qs = p.getAvailableQualityLevels() } catch(e) {}
            var lv = false, hd = false;
            try { var vd = p.getVideoData(); lv = !!(vd && (vd.isLive || vd.isLowLatencyLiveStream)) } catch(e) {}
            try { var ps = p.getProgressState(); hd = !!(ps && ps.isAtLiveHead) } catch(e) {}
            post({t:'time', pos:v.currentTime, dur:v.duration, rate:v.playbackRate, cc:cc(), q:q, qs:qs,
                  paused:v.paused, muted:v.muted, live:lv, head:hd});
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
        history = Store.read("history.json").flatMap { try? JSONDecoder().decode([VideoItem].self, from: $0) } ?? []
        cfg.userContentController.add(self, name: "yt")
        webView.navigationDelegate = self
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
        server.currentDetails = { [weak self] in self?.details }
        server.paired = { [weak self] in self?.settings.paired($0) }
        server.onPair = { [weak self] m, id, reply in self?.pairing.receive(m, from: id, send: reply) }
        server.onPeers = { [weak self] in
            self?.pending = self?.server.pending ?? []
            self?.connected = self?.server.connected ?? []
            if self?.connected.isEmpty == true { self?.watching = false }
        }
        server.onGone = { [weak self] id in self?.pairing.cancel(peer: id) }
        server.onDenied = { [weak self] in self?.denied = $0 }
        server.viewerPro = { ProStore.shared.isPro }
        server.notify = { [weak self] in self?.flash($0) }
        server.hasVideo = { [weak self] in self?.current != nil }
        pairing.onPaired = { [weak self] d in self?.server.challenge(key: d.key) }
        pairedObs = settings.$paired.dropFirst().sink { [weak self] list in self?.server.keep(Set(list.map(\.key))) }
        server.start(name: settings.name, key: settings.deviceKey)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickSleep()
            self?.broadcast()
        }
        activeObs = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let s = self?.screen { Log.add("app active, brightness \(Int((s.brightness * 100).rounded()))%") }
        }
        brightnessObs = NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let s = self.screen else { return }
            if let l = self.lastBrightnessSet, Date().timeIntervalSince(l.at) < 1.5, abs(l.value - s.brightness) < 0.02 { return }
            Log.add("brightness changed by the system or the user: \(Int((s.brightness * 100).rounded()))%")
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
        stopScan(resume: false)
        server.stop()
        sleepEndsAt = nil
        sleepAtEnd = false
        sleepAtQueueEnd = false
        pairedObs = nil
        pairing.cancel()
        timer?.invalidate()
        volumeObs = nil
        if let o = interruptObs { NotificationCenter.default.removeObserver(o) }
        interruptObs = nil
        if let o = activeObs { NotificationCenter.default.removeObserver(o) }
        activeObs = nil
        if let o = brightnessObs { NotificationCenter.default.removeObserver(o) }
        brightnessObs = nil
        restoreBrightness()
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

    func endSession() {
        Log.add("session ended")
        sleepEndsAt = nil
        sleepAtEnd = false
        sleepAtQueueEnd = false
        queue = []
        goIdle()
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

    func togglePictureInPicture() { js("__tr.pip()") }

    func rename() {
        if running { server.rename(name: settings.name, key: settings.deviceKey) }
    }

    // MARK: Commands

    func handle(_ cmd: Command, from who: String?) {
        if let verb = apply(cmd), let who { flash("\(verb) from \(who)") }
        // The queue is sent to every remote each second, and a message over 1 MiB is dropped, so it has a limit.
        if queue.count > Self.maxQueue { queue.removeLast(queue.count - Self.maxQueue) }
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
            restoreBrightness()
            isPlaying = true
            wantPlaying = true
            if running { UIApplication.shared.isIdleTimerDisabled = true }
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
        case .setBrightness(let v):
            brightnessBeforeSleep = nil
            setScreenBrightness(CGFloat(min(max(v, 0), 1)), why: "remote")
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
        case .setAutoplay(let on):
            settings.autoplay = on
            objectWillChange.send()
            candidateFor = nil
            if !on {
                awaitingNext = false
                autoplayNext = nil
            }
            return on ? "Autoplay on" : "Autoplay off"
        case .setRichView(let on):
            guard on == false || current != nil else { return nil }
            richView = on
            richTab = 0
            richScroll = 0
            richPosition = nil
            if on { ensureDetails() }
            return nil
        case .richScroll(let i):
            guard richView else { return nil }
            richScroll = min(max(i, 0), 5000)
            return nil
        case .richPosition(let p):
            guard richView else { return nil }
            richPosition = min(max(p, 0), 1000)
            return nil
        case .scan(let d, let mute):
            guard current != nil else { return nil }
            if d == 0 {
                stopScan()
            } else {
                scanSeen = Date()
                let dir = d > 0 ? 1 : -1
                if scanDir != dir { startScan(dir, mute: mute) }
            }
            return nil
        case .scanEnd(let held):
            guard scanDir != 0 else { return nil }
            let expected = scanStart + Double(scanDir) * ScanRamp.distance(held: min(max(held.isFinite ? held : 0, 0), 120), cap: scanCap)
            stopScan()
            seek(max(0, duration > 0 ? min(expected, duration) : expected))
            return nil
        case .goLive:
            guard live else { return nil }
            seekHoldUntil = Date().addingTimeInterval(1.5)
            js("__tr.goLive()")
            return nil
        case .toggleComment(let id):
            guard needsDetails, var d = currentDetails(), let i = d.comments.firstIndex(where: { $0.id == id }) else { return nil }
            if d.expanded.contains(id) {
                d.expanded = []
            } else {
                d.expanded = [id]
                if d.comments[i].replyList == nil {
                    if let tok = replyTokens[id], !replyLoading.contains(id) {
                        replyLoading.insert(id)
                        js("__tr.replies(\(Self.jsString(id)), \(Self.jsString(tok)))")
                    } else if replyTokens[id] == nil {
                        Log.add("replies: no reply token for this comment (\(replyTokens.count) of \(d.comments.count) comments have one)")
                        d.comments[i].replyList = []
                    }
                }
            }
            publish(d)
            return nil
        case .richTab(let i):
            guard richView else { return nil }
            richTab = min(max(i, 0), 1)
            richScroll = 0
            richPosition = nil
            return nil
        case .watchDetails(let on):
            watching = on
            if on { ensureDetails() }
            return nil
        case .moreComments:
            guard needsDetails, !commentsLoading, let tok = commentsNext else { return nil }
            commentsLoading = true
            js("__tr.comments(\(Self.jsString(tok)))")
            return nil
        case .autoplayAnother:
            guard let n = autoplayNext else { return nil }
            skipExtra.append(n.videoID)
            autoplayNext = nil
            candidateFor = nil
            return nil
        case .setSleepTimer(let s):
            sleepAtEnd = false
            sleepAtQueueEnd = false
            guard let s, s.isFinite, s >= -1 else {
                sleepEndsAt = nil
                return "Sleep timer off"
            }
            if s == -1 {
                guard current != nil else { return nil }
                sleepAtQueueEnd = true
                sleepEndsAt = queueEndEstimate()
            } else if s == 0 {
                guard current != nil, duration > 0 else { return nil }
                sleepAtEnd = true
                sleepEndsAt = Date().addingTimeInterval(max(duration - position, 0))
            } else {
                sleepEndsAt = Date().addingTimeInterval(min(s, 12 * 3600))
            }
            return "Sleep timer set"
        case .playlist(let items, let action):
            // Arrives over the network: only valid ids, and not more than the queue holds.
            let list = items.filter(\.isValid).prefix(Self.maxQueue).map(\.fresh)
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

    private func queueEndEstimate() -> Date {
        Date().addingTimeInterval(max(duration - position, 0) + queue.compactMap(\.duration).reduce(0, +))
    }

    private func tickSleep() {
        if sleepAtEnd || sleepAtQueueEnd {
            let end = sleepAtQueueEnd ? queueEndEstimate() : Date().addingTimeInterval(max(duration - position, 0))
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
        sleepAtQueueEnd = false
        _ = apply(.pause)
        // iOS has no call to lock the screen. Letting go of the "stay awake" hold makes the device lock after its Auto-Lock time.
        UIApplication.shared.isIdleTimerDisabled = false
        if brightnessBeforeSleep == nil, let s = screen {
            brightnessBeforeSleep = s.brightness
            setScreenBrightness(0, why: "sleep timer")
        }
        flash("Sleep timer ended")
    }

    private func restoreBrightness() {
        guard let b = brightnessBeforeSleep else { return }
        brightnessBeforeSleep = nil
        setScreenBrightness(b, why: "put back")
    }

    private func setScreenBrightness(_ v: CGFloat, why: String) {
        guard let s = screen else { return }
        lastBrightnessSet = (v, Date())
        s.brightness = v
        if why != "remote" || Date().timeIntervalSince(lastBrightnessLog) > 1 {
            lastBrightnessLog = Date()
            Log.add("brightness set to \(Int((v * 100).rounded()))% (\(why))")
        }
    }

    private func start(_ item: VideoItem, pushPrevious: Bool = true, auto: Bool = false) {
        restoreBrightness()
        server.videoChanged()
        autoplayStreak = auto ? autoplayStreak + 1 : 0
        live = false
        atLiveHead = false
        liveReloaded = false
        stopScan(resume: false)
        scanDir = 0
        awaitingNext = false
        autoplayNext = nil
        candidateFor = nil
        skipExtra = []
        details = nil
        commentsNext = nil
        commentsLoading = false
        replyTokens = [:]
        replyLoading = []
        richScroll = 0
        richPosition = nil
        if pushPrevious, let c = current { pushHistory(c) }
        // A resumed video starts where it left off. It arrives over the network, so only a sensible time is used.
        let at = item.startAt.flatMap { $0.isFinite && $0 > 5 ? min($0, 86_400) : nil }
        current = item
        position = at ?? 0
        duration = item.duration ?? 0
        // An "end of video" timer belongs to the video it was set on.
        if sleepAtEnd {
            sleepAtEnd = false
            sleepEndsAt = nil
        }
        isPlaying = true
        wantPlaying = true
        if running { UIApplication.shared.isIdleTimerDisabled = true }
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
        wantQuality = settings.preferredQuality == "auto" ? nil : settings.preferredQuality
        autoQuality = wantQuality == nil
        // Saved sign-in cookies must be back in place before the page loads, or it loads signed out.
        browser.restoreCookies { [weak self] in
            guard let self, self.current?.id == item.id else { return }
            self.webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(item.videoID)" + (at.map { "&t=\(Int($0))s" } ?? ""))!))
        }
    }

    private func startIfIdle() {
        if current == nil { advance() }
    }

    private func advance() {
        if !queue.isEmpty { return start(queue.removeFirst()) }
        if !sleepAtQueueEnd, settings.autoplay, sessionPro, current != nil, autoplayStreak < Self.maxAutoplay {
            if let n = autoplayNext { return start(n, auto: true) }
            return askUpNext()
        }
        goIdle()
    }

    private func goIdle() {
        stopScan(resume: false)
        richView = false
        details = nil
        awaitingNext = false
        autoplayNext = nil
        candidateFor = nil
        if let c = current { pushHistory(c) }
        current = nil
        isPlaying = false
        position = 0
        duration = 0
        webView.loadHTMLString("<body style='background:#000'>", baseURL: nil)
        if sleepAtQueueEnd { sleepFire() }
    }

    private func askUpNext() {
        guard !awaitingNext else { return }
        awaitingNext = true
        askPage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.upNext(nil) }
    }

    private func askPage() {
        let skip = [current?.videoID].compactMap { $0 } + history.prefix(20).map(\.videoID) + skipExtra
        let json = (try? JSONSerialization.data(withJSONObject: skip)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        js("__tr.next(\(json))")
    }

    private func prefetchNext(for c: VideoItem) {
        candidateFor = c.id
        askPage()
    }

    private func prefetched(_ id: String?) {
        guard let was = current?.id, let id else { return }
        Task { @MainActor in
            let item = await VideoMetadata.item(videoID: id, duration: nil)
            guard current?.id == was, candidateFor == was, item.isValid else { return }
            autoplayNext = item
            Log.add("autoplay next \(id)")
            broadcast()
        }
    }

    func upNext(_ id: String?) {
        guard awaitingNext else { return }
        awaitingNext = false
        guard let was = current?.id else { return }
        guard let id = id ?? history.dropFirst(5).map(\.videoID).randomElement() else { return goIdle() }
        Log.add("autoplay \(id)")
        Task { @MainActor in
            let item = await VideoMetadata.item(videoID: id, duration: nil)
            guard current?.id == was else { return }
            guard item.isValid else { return goIdle() }
            if queue.isEmpty { start(item, auto: true) } else { advance() }
        }
    }

    private static func jsString(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    private func currentDetails() -> VideoDetails? {
        guard let id = current?.videoID else { return nil }
        if let d = details, d.videoID == id { return d }
        return VideoDetails(videoID: id)
    }

    private static func comment(_ c: [String: Any]) -> VideoComment? {
        guard let id = c["id"] as? String, let text = c["t"] as? String, !text.isEmpty else { return nil }
        func s(_ k: String) -> String? { (c[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return VideoComment(id: id, author: String((c["a"] as? String ?? "").prefix(100)), text: String(text.prefix(1000)),
                            likes: s("l"), age: s("w"), replies: s("r"))
    }

    private func publish(_ d: VideoDetails) {
        details = d
        server.broadcastDetails(d)
    }

    private func loadInfo() {
        guard let d = currentDetails() else { return }
        infoTries = 0
        if details?.videoID != d.videoID { details = d }
        js("__tr.info()")
    }

    private func loadComments() {
        commentsNext = nil
        commentsLoading = true
        js("__tr.comments(null)")
    }

    private func ensureDetails() {
        guard let id = current?.videoID, !loading else { return }
        if details?.videoID != id { loadInfo() }
        if needsDetails, details?.commentsStatus == nil, !commentsLoading { loadComments() }
        if let d = details { server.broadcastDetails(d) }
    }

    private func startScan(_ dir: Int, mute: Bool) {
        let was = scanDir != 0 ? scanWasPlaying : wantPlaying
        stopScan(resume: false)
        scanWasPlaying = was
        scanDir = dir
        scanStart = position
        scanStartedAt = Date()
        scanTick = scanStartedAt
        scanCap = ScanRamp.cap(duration: duration)
        scanMuted = mute
        if mute { js("__tr.scanMute(true)") }
        if dir > 0 { js("__tr.scan(\(ScanRamp.base))") } else { js("__tr.pause()") }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.scanStep() }
    }

    private func scanStep() {
        if Date().timeIntervalSince(scanSeen) > 1.5 || (scanDir < 0 && position <= 1) { return stopScan() }
        let now = Date()
        let speed = ScanRamp.speed(at: now.timeIntervalSince(scanStartedAt), cap: scanCap)
        let dt = now.timeIntervalSince(scanTick)
        scanTick = now
        if scanDir > 0 {
            js("__tr.scan(\(min(speed, Self.maxScanRate)))")
            if speed > Self.maxScanRate { seek(position + (speed - Self.maxScanRate) * dt) }
        } else {
            seek(max(position - speed * dt, 0))
        }
        broadcast()
    }

    private func stopScan(resume: Bool = true) {
        scanTimer?.invalidate()
        scanTimer = nil
        guard scanDir != 0 else { return }
        if scanMuted { js("__tr.scanMute(false)") }
        scanMuted = false
        if scanDir > 0 { js("__tr.scan(0)") } else if resume, scanWasPlaying { js("__tr.play()") }
        scanDir = 0
        if resume { broadcast() }
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
        seekHoldUntil = Date().addingTimeInterval(1.5)
        js("__tr.seek(\(clamped))")
    }

    private func pushHistory(_ item: VideoItem) {
        var item = item
        item.startAt = nil
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
            loadInfo()
            if needsDetails { loadComments() }
        case "tap":
            tapped.send()
        case "dtap":
            let side = b["side"] as? Int ?? 0
            guard side != 0, current != nil else { break }
            let n = settings.skipSeconds
            seek(position + Double(side * n))
            flash(side > 0 ? "+\(n) s" : "-\(n) s")
            broadcast()
        case "perr":
            guard let id = current?.videoID else { break }
            if b["forced"] as? Bool == true {
                Log.add("player error with quality forced, back to Auto")
                wantQuality = nil
                autoQuality = true
                flash("That quality won't play on this device. Back to Auto.", shared: true)
                loading = true
                webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(id)&t=\(Int(position))s")!))
            } else {
                Log.add("player error screen")
                flash("Can't play \(current?.title ?? "video") here, skipping", shared: true)
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
            flash("Picture in Picture isn't available. YouTube allows it with Premium.")
        case "info":
            let id = b["id"] as? String ?? ""
            let title = b["title"] as? String ?? ""
            if id != "", id != current?.videoID { break }
            if title.isEmpty {
                guard infoTries < 3 else { break }
                infoTries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.js("__tr.info()") }
                break
            }
            guard var d = currentDetails() else { break }
            d.info = VideoInfo(videoID: d.videoID, title: title, channel: b["channel"] as? String ?? "",
                               views: Int(b["views"] as? String ?? ""), published: b["date"] as? String,
                               description: String((b["desc"] as? String ?? "").prefix(5000)))
            d.storyboard = (b["sb"] as? String).flatMap { $0.isEmpty || $0.count > 4000 ? nil : $0 }
            publish(d)
        case "comments":
            commentsLoading = false
            guard needsDetails, var d = currentDetails() else { break }
            let items = b["items"] as? [[String: Any]] ?? []
            let have = Set(d.comments.map(\.id))
            let fresh = items.compactMap { c -> VideoComment? in
                guard let id = c["id"] as? String, !have.contains(id) else { return nil }
                if let rt = c["rt"] as? String, !rt.isEmpty { replyTokens[id] = rt }
                return Self.comment(c)
            }
            d.comments = Array((d.comments + fresh).prefix(Self.maxComments))
            commentsNext = d.comments.count >= Self.maxComments ? nil : b["next"] as? String
            d.moreComments = commentsNext != nil
            d.commentsStatus = b["status"] as? String ?? "error"
            publish(d)
        case "replies":
            guard let cid = b["cid"] as? String else { break }
            replyLoading.remove(cid)
            guard var d = currentDetails(), let i = d.comments.firstIndex(where: { $0.id == cid }) else { break }
            d.comments[i].replyList = (b["items"] as? [[String: Any]] ?? []).compactMap { Self.comment($0) }.prefix(20).map { $0 }
            publish(d)
        case "next":
            if awaitingNext { upNext(b["id"] as? String) } else { prefetched(b["id"] as? String) }
        case _ where loading:
            break
        case "ad":
            let skip = b["skip"] as? Bool ?? false
            if skip != adSkippable {
                adSkippable = skip
                broadcast()
            }
        case "time":
            if let p = b["pos"] as? Double, p.isFinite, Date() >= seekHoldUntil { position = p }
            if let c = current, queue.isEmpty, settings.autoplay, sessionPro, autoplayStreak < Self.maxAutoplay,
               candidateFor != c.id, !awaitingNext, position > 5 {
                prefetchNext(for: c)
            }
            if let d = b["dur"] as? Double, d.isFinite, d > 0 {
                duration = d
                if current?.duration != d { current?.duration = d }
            }
            if scanTimer == nil, let r = b["rate"] as? Double, r != speed { speed = r }
            live = b["live"] as? Bool ?? false
            atLiveHead = b["head"] as? Bool ?? false
            if let c = b["cc"] as? Bool, c != captions { captions = c }
            // YouTube starts the first video of a session muted, and it can stall while starting. Judge by the
            // playback position: if it has not moved for over a second in the first 25 seconds, try the next
            // way of starting it. Once it is moving, unmute it if it is still muted.
            let now = Date()
            if let p = b["pos"] as? Double, abs(p - lastPos) > 0.05 { lastPos = p; lastMove = now }
            let notMoving = now.timeIntervalSince(lastMove) > 1.2
            if live, wantPlaying, !liveReloaded, now.timeIntervalSince(lastMove) > 20, let id = current?.videoID {
                liveReloaded = true
                Log.add("live stream has stopped moving, reloading it as a video")
                loading = true
                lastMove = now
                lastPos = -1
                startedAt = now
                webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(id)&t=\(max(Int(position) - 10, 0))s")!))
                break
            }
            if wantPlaying, scanDir == 0, notMoving, now.timeIntervalSince(startedAt) < 25, now.timeIntervalSince(lastKick) > 1.2 {
                lastKick = now
                Log.add("not moving at \(lastPos) paused=\(b["paused"] ?? "?") muted=\(b["muted"] ?? "?"), attempt \(kickCount % 3)")
                js("__tr.kick(\(kickCount % 3))")
                kickCount += 1
            } else if wantPlaying, scanDir == 0, !notMoving, b["muted"] as? Bool == true, now.timeIntervalSince(lastKick) > 1 {
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
                if scanDir != 0 { break }
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
            flash("Can't play \(current?.title ?? "video") here, skipping", shared: true)
            advance()
            broadcast()
        default:
            break
        }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { loadFailed(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { loadFailed(e) }

    private func loadFailed(_ e: Error) {
        guard loading, (e as NSError).code != NSURLErrorCancelled, let c = current else { return }
        Log.add("page load failed: \((e as NSError).code)")
        flash("Can't load \(c.title), skipping", shared: true)
        advance()
        broadcast()
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        guard let id = current?.videoID else { return }
        Log.add("web process ended, reloading")
        loading = true
        w.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(id)&t=\(Int(position))s")!))
    }

    // MARK: State out

    func snapshot() -> ViewerState {
        ViewerState(deviceName: settings.name, current: current, isPlaying: isPlaying,
                    position: position, duration: duration, volume: volume, queue: queue, history: history,
                    speed: speed, captions: captions, quality: quality, qualities: qualities,
                    adSkippable: adSkippable, preferredQuality: settings.preferredQuality, sleepEndsAt: sleepEndsAt,
                    autoQuality: autoQuality, captionsStatus: captionsStatus, sessionPro: sessionPro,
                    autoplay: settings.autoplay, autoplayNext: autoplayNext,
                    richView: richView, richTab: richTab, live: live, liveHead: atLiveHead,
                    needsUnmute: needsUnmute ? true : nil, notice: toastShared ? toast : nil,
                    brightness: screen.map { Float($0.brightness) })
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

    private func flash(_ s: String, shared: Bool = false) {
        toastShared = shared
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
}
