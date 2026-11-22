import Foundation

struct SharedConfig: Codable {
    var deviceKey: String
    var deviceName: String
    var paired: [PairedDevice]
    var lastViewer: String?
    var pro: Bool

    static let group = "group.com.exaltedpixels.TubeRemote"

    static var available: Bool { url != nil }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("share.json")
    }

    static func read() -> SharedConfig? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedConfig.self, from: data)
    }

    @discardableResult
    func write() -> Bool {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return false }
        do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } catch { return false }
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return true
    }
}
