import CryptoKit
import Foundation
import Network

enum ShareError: Error { case notFound, dropped, unpaired, version }

/// Finds one paired viewer on the network, signs in the way the app's remote does, sends one command and hangs up.
/// Everything runs on the main queue and `done` is called once.
final class ShareSender {
    private let config: SharedConfig
    private let device: PairedDevice
    private let command: Command
    private let done: (Result<Void, ShareError>) -> Void
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var channel: Channel?
    private var sent = false
    private var finished = false

    init(config: SharedConfig, device: PairedDevice, command: Command, done: @escaping (Result<Void, ShareError>) -> Void) {
        self.config = config
        self.device = device
        self.command = command
        self.done = done
    }

    func start() {
        let b = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.finish(.failure(self.conn == nil ? .notFound : .dropped))
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard conn == nil else { return }
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint, name.hasSuffix("#" + device.key) {
                connect(r.endpoint)
                return
            }
        }
    }

    private func connect(_ endpoint: NWEndpoint) {
        browser?.cancel()
        browser = nil
        let c = NWConnection(to: endpoint, using: Transport.parameters())
        conn = c
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: self?.ready()
            case .failed: self?.finish(.failure(.dropped))
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func ready() {
        guard let c = conn else { return }
        Transport.send(ClientMessage.hello(name: config.deviceName, key: config.deviceKey, version: Transport.version), on: c)
        Transport.receiveLoop(c, as: ServerMessage.self, onMessage: { [weak self] in self?.handle($0) },
                              onEnd: { [weak self] in self?.finish(.failure(.dropped)) })
    }

    private func handle(_ m: ServerMessage) {
        guard let c = conn else { return }
        switch m {
        case .hello(let v):
            if v != Transport.version { finish(.failure(.version)) }
        case .challenge(let nonce):
            let mine = Transport.nonce()
            let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: device.secret))
            channel = Channel(secret: device.secret, salt: nonce + mine, viewer: false)
            Transport.send(ClientMessage.auth(mac: Data(mac), nonce: mine), on: c)
        case .sealed(let box):
            // The viewer's first sealed message is its state, which means it accepted the sign-in.
            guard !sent, let body = channel?.open(box),
                  case .state(_)? = try? JSONDecoder().decode(ServerMessage.self, from: body) else { return }
            sent = true
            guard let out = channel?.seal(ClientMessage.command(command)) else { return finish(.failure(.dropped)) }
            Transport.send(ClientMessage.sealed(out), on: c)
            // Let the message leave before closing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish(.success(())) }
        case .unpaired:
            finish(.failure(.unpaired))
        default:
            break
        }
    }

    private func finish(_ result: Result<Void, ShareError>) {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        conn?.cancel()
        done(result)
    }
}
