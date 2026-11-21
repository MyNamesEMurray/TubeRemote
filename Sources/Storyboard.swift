import UIKit

@MainActor
final class Storyboard: ObservableObject {
    private struct Level {
        let width: Int
        let height: Int
        let count: Int
        let cols: Int
        let rows: Int
        let interval: Int
        let template: String
    }

    @Published private(set) var version = 0
    private var videoID = ""
    private var spec = ""
    private var level: Level?
    private var duration = 0.0
    private var sheets: [Int: UIImage] = [:]
    private var pending = Set<Int>()
    private static let maxSheets = 8

    func reset() {
        videoID = ""
        spec = ""
        level = nil
        sheets = [:]
        pending = []
    }

    func load(spec: String?, videoID: String, duration: Double) {
        self.duration = duration
        guard let spec, !spec.isEmpty else { return reset() }
        if videoID == self.videoID, spec == self.spec { return }
        reset()
        self.videoID = videoID
        self.spec = spec
        let parts = spec.components(separatedBy: "|")
        guard parts.count > 1 else { return }
        let base = parts[0]
        let join = base.contains("?") ? "&" : "?"
        var levels: [Level] = []
        for (i, part) in parts.dropFirst().enumerated() {
            let f = part.components(separatedBy: "#")
            guard f.count >= 8, let w = Int(f[0]), let h = Int(f[1]), let n = Int(f[2]), let c = Int(f[3]),
                  let r = Int(f[4]), let iv = Int(f[5]), w > 0, h > 0, n > 0, c > 0, r > 0 else { continue }
            let url = base.replacingOccurrences(of: "$L", with: String(i)).replacingOccurrences(of: "$N", with: f[6]) + join + "sigh=" + f[7]
            levels.append(Level(width: w, height: h, count: n, cols: c, rows: r, interval: iv, template: url))
        }
        level = levels.first { $0.width >= 160 } ?? levels.last
        Log.add("storyboard: " + (level.map { "\($0.width)x\($0.height), \($0.count) frames" } ?? "no usable level"))
        if let l = level {
            let total = (l.count + l.cols * l.rows - 1) / (l.cols * l.rows)
            for n in 0..<min(total, 3) { fetch(n) }
        }
    }

    func frame(at t: Double) -> UIImage? {
        guard let l = level else { return nil }
        let byTime = l.interval > 0 ? Int(t * 1000 / Double(l.interval)) : (duration > 0 ? Int(t / duration * Double(l.count)) : 0)
        let index = max(0, min(byTime, l.count - 1))
        let per = l.cols * l.rows
        let sheet = index / per
        guard let image = sheets[sheet] else {
            fetch(sheet)
            return nil
        }
        let cell = index % per
        let rect = CGRect(x: (cell % l.cols) * l.width, y: (cell / l.cols) * l.height, width: l.width, height: l.height)
        return image.cgImage?.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    private func fetch(_ n: Int) {
        guard let l = level, sheets[n] == nil, !pending.contains(n),
              let url = URL(string: l.template.replacingOccurrences(of: "$M", with: String(n))) else { return }
        pending.insert(n)
        let id = videoID
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            pending.remove(n)
            guard id == videoID, let data, let image = UIImage(data: data) else { return }
            sheets[n] = image
            if sheets.count > Self.maxSheets, let far = sheets.keys.max(by: { abs($0 - n) < abs($1 - n) }) { sheets[far] = nil }
            version += 1
        }
    }
}
