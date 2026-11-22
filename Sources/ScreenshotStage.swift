#if DEBUG
import SwiftUI

enum ScreenshotStage {
    static var shot: String? { UserDefaults.standard.string(forKey: "TubeRemoteScreenshots") }
    static var panel: String? { shot }

    private static func video(_ id: String, _ title: String, _ channel: String, _ seconds: Double) -> VideoItem {
        VideoItem(videoID: id, title: title, channel: channel, duration: seconds)
    }

    // Blender Foundation's open movies, so the pictures are not someone else's work.
    private static let bunny = video("aqz-KE-bpKQ", "Big Buck Bunny", "Blender", 635)
    private static let spring = video("WhWc3b3KhnY", "Spring", "Blender", 464)
    private static let llamigos = video("SkVqJ1SGeL0", "Caminandes 3: Llamigos", "Blender", 150)
    private static let steel = video("R6MlUcmOul8", "Tears of Steel", "Blender", 734)
    private static let laundromat = video("Y-rmzh0PI3c", "Cosmos Laundromat: First Cycle", "Blender", 725)

    static var state: ViewerState {
        ViewerState(deviceName: "Living Room iPad", current: bunny, isPlaying: true, position: 254, duration: 635,
                    volume: 0.625, queue: [steel, laundromat, spring, llamigos], history: [laundromat, steel], speed: 1,
                    captions: false, quality: "hd1080", qualities: ["hd2160", "hd1440", "hd1080", "hd720", "large"],
                    adSkippable: false, preferredQuality: "best", sleepEndsAt: nil, autoQuality: false,
                    captionsStatus: nil, sessionPro: true)
    }
}

struct StagedShot: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var pairing: Pairing
    @StateObject private var client: RemoteClient
    @StateObject private var remote: RemoteController

    init() {
        let s = AppSettings()
        let p = Pairing(settings: s)
        let c = RemoteClient(key: "stage0001", name: "Living Room iPad", endpoints: [], settings: s, pairing: p,
                             state: ScreenshotStage.state)
        c.connected = true
        _pairing = StateObject(wrappedValue: p)
        _client = StateObject(wrappedValue: c)
        _remote = StateObject(wrappedValue: RemoteController(settings: s, pairing: p))
    }

    @ViewBuilder var body: some View {
        if ScreenshotStage.shot == "paywall" {
            PaywallView().environmentObject(ProStore.shared)
        } else {
            NowPlayingContent(client: client, dismiss: {})
                .environmentObject(settings)
                .environmentObject(remote)
                .environmentObject(pairing)
                .environmentObject(ProStore.shared)
        }
    }
}
#endif
