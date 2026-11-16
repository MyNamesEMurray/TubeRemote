import Foundation

/// What the share extension needs from the app: who this device is, which viewers it may talk to, and whether
/// Pro is on. The app writes it to the shared App Group container whenever it comes to or leaves the foreground;
/// the extension only reads it. Both targets compile this file.
struct SharedConfig: Codable {
    var deviceKey: String
    var deviceName: String
    var paired: [PairedDevice]
    var lastViewer: String?
    var queueAction: QueueAction
    var pro: Bool

    static let group = "group.com.exaltedpixels.TubeRemote"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("share.json")
    }

    static func read() -> SharedConfig? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedConfig.self, from: data)
    }

    func write() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }
}
