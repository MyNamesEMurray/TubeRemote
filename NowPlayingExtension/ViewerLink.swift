import CryptoKit
import Foundation
import Network

enum LinkError: Error { case notFound, dropped, unpaired, version, busy }

/// Runs on the main queue. The extension signs in as this device, which replaces the app's own connection to the
/// viewer, so the link is opened per burst of commands and closed after a short idle.
final class ViewerLink {
    var onState: ((ViewerState) -> Void)?
    private let key: String
    private var device: PairedDevice?
    private var config: SharedConfig?
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var channel: Channel?
    private var ready = false
    private var pending: [(Command, CheckedContinuation<Void, Error>)] = []
    private var idle: DispatchWorkItem?
    private var giveUp: DispatchWorkItem?
    private var maintainer: Timer?

    init(key: String) { self.key = key }

    /// While the app is suspended nothing else keeps the card current, so hold a link open. While the app runs it owns
    /// the connection, because signing in here would drop its.
    func maintain() {
        maintainer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if NowPlayingMailbox.appIsActive {
                if self.conn != nil && self.pending.isEmpty { self.close() }
            } else if self.conn == nil && self.browser == nil {
                self.begin()
            }
        }
    }

    func send(_ command: Command) async throws {
        if NowPlayingMailbox.appIsActive {
            NowPlayingMailbox.post(command)
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { self.enqueue(command, cont) }
        }
    }

    private func enqueue(_ command: Command, _ cont: CheckedContinuation<Void, Error>) {
        pending.append((command, cont))
        if ready { flush() } else if conn == nil && browser == nil { begin() }
    }

    private func begin() {
        guard let cfg = SharedConfig.read(), let d = cfg.paired.first(where: { $0.key == key }) else { return fail(.unpaired) }
        config = cfg
        device = d
        let b = NWBrowser(for: .bonjour(type: Transport.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        b.start(queue: .main)
        browser = b
        let w = DispatchWorkItem { [weak self] in self?.fail(self?.conn == nil ? .notFound : .dropped) }
        giveUp = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard conn == nil else { return }
        for r in results {
            if case let .service(name, _, _, _) = r.endpoint, name.hasSuffix("#" + key) {
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
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, self.conn === c else { return }
            switch s {
            case .ready: self.signIn()
            case .failed: self.fail(.dropped)
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func signIn() {
        guard let c = conn, let cfg = config else { return }
        Transport.send(ClientMessage.hello(name: cfg.deviceName, key: cfg.deviceKey, version: Transport.version, pro: cfg.pro), on: c)
        Transport.receiveLoop(c, as: ServerMessage.self, onMessage: { [weak self] in self?.handle($0, on: c) },
                              onEnd: { [weak self] in
            guard let self, self.conn === c else { return }
            self.fail(.dropped)
        })
    }

    private func handle(_ m: ServerMessage, on c: NWConnection) {
        guard conn === c, let device else { return }
        switch m {
        case .hello(let v):
            if v != Transport.version { fail(.version) }
        case .challenge(let nonce):
            let mine = Transport.nonce()
            let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: device.secret))
            channel = Channel(secret: device.secret, salt: nonce + mine, viewer: false)
            Transport.send(ClientMessage.auth(mac: Data(mac), nonce: mine), on: c)
        case .sealed(let box):
            guard let body = channel?.open(box), case .state(let st)? = try? JSONDecoder().decode(ServerMessage.self, from: body) else { return }
            if !ready {
                ready = true
                giveUp?.cancel()
                flush()
            }
            onState?(st)
        case .unpaired:
            fail(.unpaired)
        case .busy:
            fail(.busy)
        default:
            break
        }
    }

    private func flush() {
        guard let c = conn else { return }
        let items = pending
        pending = []
        for (command, cont) in items {
            guard let out = channel?.seal(ClientMessage.command(command)) else {
                cont.resume(throwing: LinkError.dropped)
                continue
            }
            Transport.send(ClientMessage.sealed(out), on: c)
            cont.resume()
        }
        guard maintainer == nil else { return }
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.close() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }

    private func fail(_ error: LinkError) {
        let items = pending
        pending = []
        close()
        for (_, cont) in items { cont.resume(throwing: error) }
    }

    private func close() {
        idle?.cancel()
        giveUp?.cancel()
        browser?.cancel()
        browser = nil
        let c = conn
        conn = nil
        c?.cancel()
        channel = nil
        ready = false
    }
}
