import SwiftUI
import WebKit

/// The embedded YouTube site. Tracks which video page is open.
final class Browser: NSObject, ObservableObject {
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
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com")!))
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
