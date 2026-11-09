import CryptoKit
import Foundation
import Network

/// JSON messages over plain TCP, each prefixed by a 4-byte big-endian length, advertised via Bonjour.
/// Everything runs on the main queue. A relay server for remote-over-internet can speak the same messages.
enum Transport {
    static let serviceType = "_ytremote._tcp"
    static let maxMessage = 1 << 20

    static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        if let tcp = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        return p
    }

    static func send<T: Encodable>(_ msg: T, on c: NWConnection) {
        guard let body = try? JSONEncoder().encode(msg) else { return Log.add("tx encode failed: \(T.self)") }
        var len = UInt32(body.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + body
        c.send(content: frame, completion: .idempotent)
    }

    static func receiveLoop<T: Decodable>(
        _ c: NWConnection, as type: T.Type,
        onMessage: @escaping (T) -> Void, onEnd: @escaping () -> Void
    ) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, error in
            guard error == nil, let head, head.count == 4 else {
                Log.add("rx header ended: \(error.map { "\($0)" } ?? "closed")")
                return onEnd()
            }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n > 0, n <= maxMessage else {
                Log.add("rx bad length \(n)")
                return onEnd()
            }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, error in
                guard error == nil, let body, body.count == n else {
                    Log.add("rx body ended: \(error.map { "\($0)" } ?? "closed")")
                    return onEnd()
                }
                if let m = try? JSONDecoder().decode(T.self, from: body) { onMessage(m) } else { Log.add("rx decode failed (\(n) bytes)") }
                receiveLoop(c, as: type, onMessage: onMessage, onEnd: onEnd)
            }
        }
    }
}

struct PendingPeer: Identifiable {
    let id: ObjectIdentifier
    let name: String
}

/// Viewer side: accepts any number of remotes. Only authenticated remotes get state and may send commands.
final class ViewerServer {
    private struct Peer {
        let conn: NWConnection
        var name = "a remote"
        var last = Date()
        var hello = false
        var key: String?
        var nonce: Data?
        var authed = false
    }

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Peer] = [:]
    private var running = false
    private var sweeper: Timer?

    var onCommand: ((Command, String) -> Void)?
    var snapshot: (() -> ViewerState?)?
    var paired: ((String) -> PairedDevice?)?
    var onPair: ((PairMessage, @escaping (PairMessage) -> Void) -> Void)?
    var onPeers: (() -> Void)?

    /// Remotes that said hello but are not authenticated, so they can be offered for pairing.
    var pending: [PendingPeer] {
        conns.compactMap { $0.value.hello && !$0.value.authed ? PendingPeer(id: $0.key, name: $0.value.name) : nil }
            .sorted { $0.name < $1.name }
    }

    func start(name: String, key: String) {
        stop()
        running = true
        guard let l = try? NWListener(using: Transport.parameters()) else { return }
        l.service = NWListener.Service(name: "\(name.prefix(40))#\(key)", type: Transport.serviceType)
        l.serviceRegistrationUpdateHandler = { Log.add("service \($0)") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            Log.add("listener \(state) port \(self?.listener?.port.map { "\($0)" } ?? "-")")
            guard case .failed = state else { return }
            self?.listener = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, self.running, self.listener == nil else { return }
                self.start(name: name, key: key)
            }
        }
        l.start(queue: .main)
        Log.add("listener starting as \(name)#\(key)")
        listener = l
        sweeper = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (id, e) in self.conns where Date().timeIntervalSince(e.last) > (e.hello ? 15 : 5) {
                Log.add("dropping silent remote \(e.name) hello=\(e.hello)")
                e.conn.cancel()
                self.remove(id)
            }
        }
    }

    func rename(name: String, key: String) {
        listener?.service = NWListener.Service(name: "\(name.prefix(40))#\(key)", type: Transport.serviceType)
    }

    func stop() {
        sweeper?.invalidate()
        sweeper = nil
        running = false
        listener?.cancel()
        listener = nil
        conns.values.forEach { $0.conn.cancel() }
        conns = [:]
        onPeers?()
    }

    func broadcast(_ state: ViewerState) {
        for p in conns.values {
            if p.authed {
                Transport.send(ServerMessage.state(state), on: p.conn)
            } else if p.hello, p.nonce == nil {
                Transport.send(ServerMessage.unpaired, on: p.conn)
            }
        }
    }

    func send(_ m: ServerMessage, to id: ObjectIdentifier) {
        if let c = conns[id]?.conn { Transport.send(m, on: c) }
    }

    /// A pairing just finished: let the remote with this key in without a challenge.
    func markAuthed(key: String) {
        for id in conns.keys where conns[id]?.key == key {
            conns[id]?.authed = true
            conns[id]?.nonce = nil
            if let s = snapshot?() { send(.state(s), to: id) }
        }
        onPeers?()
    }

    private func remove(_ id: ObjectIdentifier) {
        conns[id] = nil
        onPeers?()
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        conns[id] = Peer(conn: c)
        Log.add("accepted \(c.endpoint)")
        c.stateUpdateHandler = { [weak self] s in
            Log.add("inbound \(s)")
            switch s {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        c.start(queue: .main)
        Transport.receiveLoop(c, as: ClientMessage.self, onMessage: { [weak self] m in
            self?.conns[id]?.last = Date()
            self?.handle(m, id: id, conn: c)
        }, onEnd: { [weak self] in
            self?.remove(id)
            c.cancel()
        })
    }

    private func handle(_ m: ClientMessage, id: ObjectIdentifier, conn: NWConnection) {
        switch m {
        case .hello(let name, let key):
            if conns[id]?.hello == false { Log.add("hello from \(name)") }
            conns[id]?.name = name
            conns[id]?.hello = true
            conns[id]?.key = key
            conns[id]?.authed = false
            if paired?(key) != nil {
                let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
                conns[id]?.nonce = nonce
                send(.challenge(nonce), to: id)
            } else {
                conns[id]?.nonce = nil
                send(.unpaired, to: id)
            }
            onPeers?()
        case .auth(let mac):
            guard let p = conns[id], let nonce = p.nonce, let key = p.key, let d = paired?(key),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: nonce, using: SymmetricKey(data: d.secret))
            else {
                Log.add("auth failed for \(conns[id]?.name ?? "?")")
                conns[id]?.nonce = nil
                send(.unpaired, to: id)
                return
            }
            conns[id]?.authed = true
            conns[id]?.nonce = nil
            Log.add("authenticated \(p.name)")
            if let s = snapshot?() { send(.state(s), to: id) }
            onPeers?()
        case .ping:
            break
        case .pair(let pm):
            guard conns[id]?.hello == true else { return }
            onPair?(pm) { Transport.send(ServerMessage.pair($0), on: conn) }
        case .command(let cmd):
            guard conns[id]?.authed == true else { return Log.add("ignored command from unauthenticated remote") }
            Log.add("command \(cmd) from \(conns[id]?.name ?? "?")")
            onCommand?(cmd, conns[id]?.name ?? "a remote")
        }
    }
}
