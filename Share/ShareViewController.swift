import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The sheet that appears under Share > Send to Viewer. It sends one video to a paired viewer and closes.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start()
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State {
        case working(String)
        case pick([PairedDevice])
        case done(String)
        case failed(String)
    }

    @Published var state = State.working("Reading the link…")
    private weak var context: NSExtensionContext?
    private var config: SharedConfig?
    private var command: Command?
    private var sender: ShareSender?

    init(context: NSExtensionContext?) { self.context = context }

    func start() {
        Task {
            guard SharedConfig.available else {
                return state = .failed("This build of TubeRemote cannot share data with its extension: the App Group is missing.")
            }
            guard let config = SharedConfig.read() else {
                return state = .failed("Open TubeRemote once on this device, then try again.")
            }
            guard !config.paired.isEmpty else {
                return state = .failed("Open TubeRemote and pair a viewer first.")
            }
            self.config = config
            guard config.pro else {
                return state = .failed("Sharing to a viewer is a TubeRemote Pro feature. Open TubeRemote to unlock it.")
            }
            guard let url = await link(), let id = parseVideoID(url) else {
                return state = .failed("Share a YouTube video link.")
            }
            command = QueueAction.addToEnd.command(await VideoMetadata.item(videoID: id, duration: nil))
            if let d = config.paired.first(where: { $0.key == config.lastViewer }) ?? (config.paired.count == 1 ? config.paired[0] : nil) {
                send(to: d)
            } else {
                state = .pick(config.paired)
            }
        }
    }

    func send(to d: PairedDevice) {
        guard let config, let command else { return }
        state = .working("Sending to \(d.name)…")
        let s = ShareSender(config: config, device: d, command: command) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.state = .done(d.name)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.close() }
            case .failure(let e):
                self.state = .failed(Self.message(e, d.name))
            }
        }
        sender = s
        s.start()
    }

    func close() { context?.completeRequest(returningItems: nil) }

    func cancel() { context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

    private static func message(_ e: ShareError, _ name: String) -> String {
        switch e {
        case .notFound: return "Couldn't find \(name) on this network. Is TubeRemote open on it as a viewer? Check that TubeRemote may use the local network in Settings."
        case .dropped: return "Lost the connection to \(name)."
        case .unpaired: return "\(name) no longer recognises this device. Open TubeRemote and pair again."
        case .version: return "Update TubeRemote on both devices."
        case .busy: return "\(name) is in use by another remote."
        }
    }

    /// The link being shared: a URL, or the first link inside shared text.
    private func link() async -> URL? {
        let items = (context?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let v = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) {
                    if let u = v as? URL { return u }
                    if let s = v as? String, let u = URL(string: s) { return u }
                }
                if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let v = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier), let s = v as? String,
                   let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
                   let u = d.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.url { return u }
            }
        }
        return nil
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 18) {
            switch model.state {
            case .working(let text):
                ProgressView()
                Text(text).font(.headline).multilineTextAlignment(.center)
            case .done(let name):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
                Text("Sent to \(name)").font(.headline)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text(text).multilineTextAlignment(.center)
                Button("Close") { model.cancel() }.buttonStyle(.borderedProminent)
            case .pick(let list):
                Text("Send to which viewer?").font(.headline)
                ForEach(list) { d in
                    Button(d.name) { model.send(to: d) }.buttonStyle(.bordered).controlSize(.large)
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
