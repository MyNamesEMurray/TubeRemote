import Combine
import SwiftUI
import WebKit

/// The embedded YouTube site. Tracks which video page is open.
final class Browser: NSObject, ObservableObject, WKHTTPCookieStoreObserver, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    @Published var videoID: String?
    @Published var canGoBack = false
    /// Fires when the person taps the play cover over the page's own player.
    let playTapped = PassthroughSubject<Void, Never>()
    private var obs: [NSKeyValueObservation] = []
    /// Name of the selected viewer, shown on the play cover. Empty when none is selected.
    var target = "" { didSet { if target != oldValue { pushTarget() } } }
    private var loaded = false
    private var restored = false
    /// nil until the cookie restore starts; callers queued while it runs.
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
        pill.textContent='\u25B6\uFE0E  '+(window.__trTarget?'Play on '+window.__trTarget:'Choose a viewer');
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
        cfg.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        // iPad asks for desktop sites by default; the play cover is written for the mobile site.
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "tr")
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        obs = [
            webView.observe(\.url) { [weak self] w, _ in
                DispatchQueue.main.async {
                    self?.videoID = parseVideoID(w.url)
                    w.evaluateJavaScript("window.__allowPlay=false")
                }
            },
            webView.observe(\.canGoBack) { [weak self] w, _ in
                DispatchQueue.main.async { self?.canGoBack = w.canGoBack }
            },
        ]
    }

    /// Loads YouTube the first time a browsing screen appears, so a viewer that never browses never loads it.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        restoreCookies { [weak self] in
            self?.webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
        }
    }

    /// Puts the saved sign-in cookies back, once, then runs `done`. The viewer's player shares this cookie store.
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

    /// A fresh page forgets the viewer name, so tell it again.
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

/// Puts an existing UIKit view (a web view, the system volume slider) into SwiftUI.
struct Hosted<V: UIView>: UIViewRepresentable {
    let view: V
    func makeUIView(context: Context) -> V { view }
    func updateUIView(_ uiView: V, context: Context) {}
}

struct BrowserBack: View {
    @EnvironmentObject var browser: Browser

    var body: some View {
        if browser.canGoBack {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back")
        }
    }
}
