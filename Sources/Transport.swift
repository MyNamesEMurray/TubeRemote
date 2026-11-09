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
        guard let body = try? JSONEncoder().encode(msg) else { return }
        var len = UInt32(body.count).bigEndian
        let frame = Data(bytes: &len, count: 4) + body
        c.send(content: frame, completion: .idempotent)
    }

    static func receiveLoop<T: Decodable>(
        _ c: NWConnection, as type: T.Type,
        onMessage: @escaping (T) -> Void, onEnd: @escaping () -> Void
    ) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { head, _, _, error in
            guard error == nil, let head, head.count == 4 else { return onEnd() }
            let n = Int(head.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard n > 0, n <= maxMessage else { return onEnd() }
            c.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, error in
                guard error == nil, let body, body.count == n else { return onEnd() }
                if let m = try? JSONDecoder().decode(T.self, from: body) { onMessage(m) }
                receiveLoop(c, as: type, onMessage: onMessage, onEnd: onEnd)
            }
        }
    }
}

/// Viewer side: accepts any number of remotes and broadcasts state to all of them.
final class ViewerServer {
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: (conn: NWConnection, name: String, last: Date, hello: Bool)] = [:]
    private var running = false
    private var sweeper: Timer?

    var onCommand: ((Command, String) -> Void)?
    var snapshot: (() -> ViewerState?)?

    func start(name: String, key: String) {
        stop()
        running = true
        guard let l = try? NWListener(using: Transport.parameters()) else { return }
        l.service = NWListener.Service(name: "\(name.prefix(40))#\(key)", type: Transport.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            self?.listener = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, self.running, self.listener == nil else { return }
                self.start(name: name, key: key)
            }
        }
        l.start(queue: .main)
        listener = l
        sweeper = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (id, e) in self.conns where Date().timeIntervalSince(e.last) > (e.hello ? 15 : 5) {
                e.conn.cancel()
                self.conns[id] = nil
            }
        }
    }

    func stop() {
        sweeper?.invalidate()
        sweeper = nil
        running = false
        listener?.cancel()
        listener = nil
        conns.values.forEach { $0.conn.cancel() }
        conns = [:]
    }

    func broadcast(_ state: ViewerState) {
        conns.values.forEach { Transport.send(state, on: $0.conn) }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        conns[id] = (c, "a remote", Date(), false)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.conns[id] = nil
            default: break
            }
        }
        c.start(queue: .main)
        Transport.receiveLoop(c, as: ClientMessage.self, onMessage: { [weak self] m in
            self?.conns[id]?.last = Date()
            self?.handle(m, id: id, conn: c)
        }, onEnd: { [weak self] in
            self?.conns[id] = nil
            c.cancel()
        })
    }

    private func handle(_ m: ClientMessage, id: ObjectIdentifier, conn: NWConnection) {
        switch m {
        case .hello(let name):
            conns[id]?.name = name
            conns[id]?.hello = true
            if let s = snapshot?() { Transport.send(s, on: conn) }
        case .command(let cmd):
            onCommand?(cmd, conns[id]?.name ?? "a remote")
        }
    }
}
