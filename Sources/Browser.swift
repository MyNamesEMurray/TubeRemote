import Combine
import SwiftUI
import WebKit

final class Browser: NSObject, ObservableObject, WKHTTPCookieStoreObserver, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    @Published var videoID: String?
    @Published var playlistID: String?
    @Published var canGoBack = false
    let playTapped = PassthroughSubject<Void, Never>()
    private var obs: [NSKeyValueObservation] = []
    var target = "" { didSet { if target != oldValue { pushTarget() } } }
    private var loaded = false
    private var restored = false
    private var waiting: [() -> Void]?

    // The viewer plays the video, so local playback is blocked unless "Play here" allows it.
    // The page's own player is covered with the video's picture and one button, so a tap there
    // plays the video on the viewer instead of starting a player that would only spin.
    private static let script = #"""
    (function(){
      document.addEventListener('play',function(e){
        if(!window.__allowPlay&&e.target.tagName==='VIDEO')e.target.pause()},true);
      var cover=document.createElement('div'),pill=document.createElement('div');
      cover.style.cssText='position:absolute;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;background:#000 center/cover no-repeat;-webkit-tap-highlight-color:transparent';
      pill.style.cssText='font:600 17px -apple-system,system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.72);padding:12px 22px;border-radius:999px;max-width:80%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis';
      cover.appendChild(pill);
      cover.addEventListener('click',function(e){
        e.preventDefault();e.stopPropagation();webkit.messageHandlers.tr.postMessage('play')},true);
      setInterval(function(){
        var p=document.getElementById('movie_player'),id=new URLSearchParams(location.search).get('v');
        if(!p||window.__allowPlay||location.pathname!=='/watch'||!/^[\w-]{6,20}$/.test(id||'')){cover.remove();return}
        var t=window.__trTarget;
        pill.textContent=t?(t.indexOf('Pair')===0?t:'\u25B6\uFE0E  '+t):'Choose a viewer';
        cover.style.backgroundImage='linear-gradient(rgba(0,0,0,.3),rgba(0,0,0,.3)),url(https://i.ytimg.com/vi/'+id+'/hqdefault.jpg)';
        if(cover.parentNode!==p)p.appendChild(cover);
      },300);
    })()
    """#

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Without a Safari-like UA, Google refuses sign-in inside web views.
        cfg.applicationNameForUserAgent = WebIdentity.applicationName
        // iPad asks for desktop sites by default; the play cover is written for the mobile site.
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "tr")
        webView.navigationDelegate = self
        // The strip under the page (the home indicator area) takes this colour, so YouTube's own bottom bar
        // looks as if it reaches the edge of the screen.
        webView.underPageBackgroundColor = .youTubePage
        webView.scrollView.backgroundColor = .youTubePage
        webView.allowsBackForwardNavigationGestures = true
        obs = [
            webView.observe(\.url) { [weak self] w, _ in
                DispatchQueue.main.async {
                    self?.videoID = parseVideoID(w.url)
                    self?.playlistID = parseListID(w.url)
                    w.evaluateJavaScript("window.__allowPlay=false")
                }
            },
            webView.observe(\.canGoBack) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoBack = w.canGoBack }
            },
        ]
    }

    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        restoreCookies { [weak self] in
            self?.webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
        }
    }

    func restoreCookies(_ done: @escaping () -> Void) {
        if let w = waiting {
            if w.isEmpty && restored { done() } else { waiting?.append(done) }
            return
        }
        waiting = [done]
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let saved = Self.savedCookies()
        Log.add("restoring \(saved.count) saved cookies")
        let group = DispatchGroup()
        saved.forEach { group.enter(); store.setCookie($0) { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            store.add(self)
            self.restored = true
            let run = self.waiting ?? []
            self.waiting = []
            run.forEach { $0() }
        }
    }

    private func pushTarget() {
        guard let json = try? JSONEncoder().encode(target), let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__trTarget=\(text)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { pushTarget() }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        playTapped.send()
    }

    /// YouTube's "Open App" button would leave this app; keep navigation on the web.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        let web = ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
        let store = ["apps.apple.com", "itunes.apple.com"].contains(url.host?.lowercased() ?? "")
        decisionHandler(web && !store ? .allow : .cancel)
    }

    // shortcut: WKWebView drops session cookies on relaunch, so keep a copy and give them a one-year expiry
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { cookies in
            let rows: [[String: Any]] = cookies
                .filter { $0.domain.contains("google") || $0.domain.contains("youtube") }
                .map { c in
                    var p = Dictionary(uniqueKeysWithValues: (c.properties ?? [:]).map { ($0.key.rawValue, $0.value) })
                    p.removeValue(forKey: HTTPCookiePropertyKey.discard.rawValue)
                    if p[HTTPCookiePropertyKey.expires.rawValue] == nil {
                        p[HTTPCookiePropertyKey.expires.rawValue] = Date().addingTimeInterval(365 * 86400)
                    }
                    return p
                }
            // Sign-in cookies stay on this device: keep them out of iCloud and computer backups.
            Store.write("cookies.plist", try? PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0),
                        backup: false)
        }
    }

    private static func savedCookies() -> [HTTPCookie] {
        guard let data = Store.read("cookies.plist"),
              let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }

    // Reads a playlist the way YouTube's own page does, from the signed-in page, so private playlists work too.
    // Up to 200 videos. It depends on YouTube's page data, which changes now and then.
    private static let playlistScript = #"""
    const origin = location.origin;
    const textOf = (t) => t ? (t.content || t.simpleText || (t.runs && t.runs.map((r) => r.text).join('')) || '') : '';
    const seconds = (s) => { const p = String(s).split(':').map(Number); return p.some(isNaN) ? null : p.reduce((a, x) => a * 60 + x, 0); };
    const decode = (s) => s.replace(/\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|[\s\S])/g, (m, t) =>
      (t[0] === 'x' || t[0] === 'u') && t.length > 1 ? String.fromCharCode(parseInt(t.slice(1), 16)) : ({n: '\n', t: '\t', r: '\r', b: '\b', f: '\f'}[t] || t));
    const initialData = (html) => {
      const tag = "var ytInitialData = '";
      let i = html.indexOf(tag);
      if (i >= 0) {
        i += tag.length;
        let j = i;
        for (;;) {
          j = html.indexOf("'", j);
          if (j < 0) return null;
          let k = j - 1, n = 0;
          while (html[k] === '\\') { n++; k--; }
          if (n % 2 === 0) break;
          j++;
        }
        return JSON.parse(decode(html.slice(i, j)));
      }
      const m = html.match(/ytInitialData\s*=\s*(\{[\s\S]*?\});\s*<\/script>/);
      return m ? JSON.parse(m[1]) : null;
    };
    const fromLockup = (v) => {
      const md = (v.metadata || {}).lockupMetadataViewModel || {};
      const rows = ((md.metadata || {}).contentMetadataViewModel || {}).metadataRows || [];
      const part = rows[0] && rows[0].metadataParts && rows[0].metadataParts[0];
      let duration = null;
      for (const o of (((v.contentImage || {}).thumbnailViewModel || {}).overlays || [])) {
        const b = ((o.thumbnailBottomOverlayViewModel || {}).badges || [])[0];
        const t = b && b.thumbnailBadgeViewModel && b.thumbnailBadgeViewModel.text;
        if (t) duration = seconds(t);
      }
      return {videoID: v.contentId, title: textOf(md.title), channel: part ? textOf(part.text) : '', duration};
    };
    const fromRenderer = (v) => ({
      videoID: v.videoId, title: textOf(v.title), channel: textOf(v.shortBylineText || v.longBylineText),
      duration: v.lengthSeconds ? Number(v.lengthSeconds) : (v.lengthText ? seconds(textOf(v.lengthText)) : null),
    });
    const findToken = (o) => {
      if (!o || typeof o !== 'object') return null;
      if (typeof o.token === 'string') return o.token;
      for (const k in o) { const t = findToken(o[k]); if (t) return t; }
      return null;
    };
    const collect = (o, items, tokens) => {
      if (Array.isArray(o)) { o.forEach((x) => collect(x, items, tokens)); return; }
      if (!o || typeof o !== 'object') return;
      for (const k in o) {
        const v = o[k];
        if (k === 'lockupViewModel' && v && v.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO' && v.contentId) items.push(fromLockup(v));
        else if ((k === 'playlistVideoRenderer' || k === 'playlistPanelVideoRenderer') && v && v.videoId) items.push(fromRenderer(v));
        else if (k === 'continuationItemViewModel' || k === 'continuationItemRenderer') { const t = findToken(v); if (t) tokens.push(t); }
        else collect(v, items, tokens);
      }
    };
    const res = await fetch(origin + '/playlist?list=' + encodeURIComponent(listId), {credentials: 'include'});
    const html = await res.text();
    const data = initialData(html);
    if (!data) return JSON.stringify({error: 'The playlist page was not in a format this app understands.'});
    const items = [], tokens = [];
    collect(data, items, tokens);
    let token = tokens[0];
    const cfg = window.ytcfg && window.ytcfg.get ? window.ytcfg : null;
    const keyMatch = html.match(/"INNERTUBE_API_KEY":"([^"]+)"/);
    const key = keyMatch ? keyMatch[1] : (cfg && cfg.get('INNERTUBE_API_KEY'));
    const context = (cfg && cfg.get('INNERTUBE_CONTEXT')) ||
      {client: {clientName: 'MWEB', clientVersion: (cfg && cfg.get('INNERTUBE_CLIENT_VERSION')) || '2.20250101.00.00', hl: 'en', gl: 'US'}};
    for (let n = 0; token && key && items.length < 200 && n < 10; n++) {
      const r = await fetch(origin + '/youtubei/v1/browse?key=' + key + '&prettyPrint=false',
        {method: 'POST', credentials: 'include', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({context, continuation: token})});
      if (!r.ok) break;
      const more = [], next = [];
      collect(await r.json(), more, next);
      items.push(...more);
      token = next[0];
    }
    return JSON.stringify({items: items.filter((x) => /^[A-Za-z0-9_-]{6,20}$/.test(x.videoID)).slice(0, 200), truncated: !!token});
    """#

    private struct PlaylistResult: Decodable {
        struct Row: Decodable { let videoID: String; let title: String; let channel: String; let duration: Double? }
        let items: [Row]?
        let truncated: Bool?
    }

    @MainActor
    func playlistItems(_ listID: String) async -> (items: [VideoItem], truncated: Bool)? {
        let result = try? await webView.callAsyncJavaScript(Self.playlistScript, arguments: ["listId": listID], in: nil, contentWorld: .page)
        guard let raw = result as? String, let data = raw.data(using: .utf8),
              let read = try? JSONDecoder().decode(PlaylistResult.self, from: data), let rows = read.items else { return nil }
        return (rows.map { VideoItem(videoID: $0.videoID, title: $0.title.isEmpty ? "YouTube video" : $0.title,
                                     channel: $0.channel, duration: $0.duration) }, read.truncated ?? false)
    }

    func pause() {
        webView.evaluateJavaScript("window.__allowPlay=false;document.querySelectorAll('video').forEach(function(v){v.pause()})")
    }

    func play() {
        webView.evaluateJavaScript("window.__allowPlay=true;var v=document.querySelector('video');if(v)v.play()")
    }

    @MainActor
    func makeItem() async -> VideoItem? {
        guard let id = videoID else { return nil }
        let js = "(function(){var v=document.querySelector('video');return v&&isFinite(v.duration)?v.duration:null})()"
        let dur = (try? await webView.evaluateJavaScript(js)) as? Double
        let page = (webView.title ?? "").replacingOccurrences(of: " - YouTube", with: "")
        return await VideoMetadata.item(videoID: id, duration: dur, fallbackTitle: page)
    }
}

extension UIColor {
    static let youTubePage = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 15 / 255, alpha: 1) : .white }
}

extension Color {
    static let youTubePage = Color(UIColor.youTubePage)
}

enum WebIdentity {
    /// Safari reports the same version as the OS (iOS 27.2 is Safari 27.2). A fixed old number made YouTube
    /// treat this as an old Safari, which may be why it did not offer HDR here as it does in Safari itself.
    static var applicationName: String {
        let v = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        return "Version/\(v) Safari/605.1.15"
    }
}

struct Hosted<V: UIView>: UIViewRepresentable {
    let view: V
    func makeUIView(context: Context) -> V { view }
    func updateUIView(_ uiView: V, context: Context) {}
}

struct BrowserNav: View {
    @EnvironmentObject var browser: Browser

    var body: some View {
        HStack(spacing: 4) {
            Button { browser.webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!)) } label: {
                Image(systemName: "house").frame(width: 36, height: 44)
            }
            .accessibilityLabel("YouTube home")
            .contextMenu {
                Button { browser.webView.reload() } label: { Label("Reload page", systemImage: "arrow.clockwise") }
            }
            if browser.canGoBack {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                    .accessibilityLabel("Back")
            }
        }
    }
}
