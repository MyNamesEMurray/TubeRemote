import UIKit

enum Haptics {
    private static var on: Bool { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }

    static func tap() { if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    static func pop() { if on { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() } }
    static func success() { if on { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning() { if on { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
}
