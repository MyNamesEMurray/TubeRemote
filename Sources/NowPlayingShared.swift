import Foundation
import NowPlaying

@available(iOS 27.0, *)
struct NowPlayingAttributes: RemoteMediaSessionAttributes {
    var id: String
    var viewerName: String
    var videoID: String
    var title: String
    var channel: String
    var isPlaying: Bool
    var position: Double
    var timestamp: Date
    var duration: Double
    var speed: Float
    var live: Bool
    var volume: Float
    var skip: Double
}
