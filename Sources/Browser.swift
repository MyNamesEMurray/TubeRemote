import SwiftUI
import WebKit

/// The embedded YouTube site. Tracks which video page is open.
final class Browser: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    let webView: WKWebView
    @Published var videoID: String?
    @Published var canGoBack = false
    private var obs: [NSKeyValueObservation] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Without a Safari-like UA, Google refuses sign-in inside web views.
        cfg.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        // The viewer plays the video, so block local playback unless "Play here" allows it.
        cfg.userContentController.addUserScript(WKUserScript(
            source: "document.addEventListener('play',function(e){if(!window.__allowPlay&&e.target.tagName==='VIDEO')e.target.pause()},true)",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
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
        let store = cfg.websiteDataStore.httpCookieStore
        let saved = Self.savedCookies()
        Log.add("restoring \(saved.count) saved cookies")
        let group = DispatchGroup()
        saved.forEach { group.enter(); store.setCookie($0) { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
            store.add(self)
        }
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
            Store.write("cookies.plist", try? PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0))
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

    func makeItem() async -> VideoItem? {
        guard let id = videoID else { return nil }
        let js = "(function(){var v=document.querySelector('video');return v&&isFinite(v.duration)?v.duration:null})()"
        let dur = (try? await webView.evaluateJavaScript(js)) as? Double
        return await VideoMetadata.item(videoID: id, duration: dur)
    }
}

struct HostedWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
