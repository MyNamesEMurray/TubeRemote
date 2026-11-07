import Foundation
import Network

/// JSON messages over WebSocket (Network.framework), advertised via Bonjour.
/// Everything runs on the main queue. A relay server for remote-over-internet can speak the same messages.
enum Transport {
    static let serviceType = "_ytremote._tcp"

    static func parameters() -> NWParameters {
        let p = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return p
    }

    static func send<T: Encodable>(_ msg: T, on c: NWConnection) {
        guard let data = try? JSONEncoder().encode(msg) else { return }
        let ctx = NWConnection.ContentContext(
            identifier: "msg", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    static func receiveLoop<T: Decodable>(
        _ c: NWConnection, as type: T.Type,
        onMessage: @escaping (T) -> Void, onEnd: @escaping () -> Void
    ) {
        c.receiveMessage { data, _, _, error in
            if let data, let m = try? JSONDecoder().decode(T.self, from: data) { onMessage(m) }
            if error != nil {
                onEnd()
            } else {
                receiveLoop(c, as: type, onMessage: onMessage, onEnd: onEnd)
            }
        }
    }
}

/// Viewer side: accepts any number of remotes and broadcasts state to all of them.
final class ViewerServer {
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: (conn: NWConnection, name: String)] = [:]
    private var running = false

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
    }

    func stop() {
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
        conns[id] = (c, "a remote")
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.conns[id] = nil
            default: break
            }
        }
        c.start(queue: .main)
        Transport.receiveLoop(c, as: ClientMessage.self, onMessage: { [weak self] m in
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
            if let s = snapshot?() { Transport.send(s, on: conn) }
        case .command(let cmd):
            onCommand?(cmd, conns[id]?.name ?? "a remote")
        }
    }
}
