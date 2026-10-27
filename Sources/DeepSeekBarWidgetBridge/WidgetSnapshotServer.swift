import DeepSeekBarWidgetShared
import Foundation
import Network

/// Like traex-status, keep the widget sandboxed and serve only display data on loopback.
/// All mutable state is confined to queue; no account credentials or raw responses are accepted.
public final class WidgetSnapshotServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.DeepSeekBar.widget-bridge", qos: .utility)
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var snapshotData: Data?

    public init(port: UInt16 = WidgetBridge.port) { self.port = port }

    public func start(onStateChange: @escaping @Sendable (Result<UInt16, WidgetBridge.BridgeError>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue { onStateChange(.success(port)) }
                    case .failed, .waiting:
                        onStateChange(.failure(.unavailable))
                    default: break
                    }
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch { onStateChange(.failure(.unavailable)) }
        }
    }

    public func publish(_ snapshot: WidgetSnapshot, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshotData = try? JSONEncoder().encode(snapshot)
            completion?()
        }
    }

    public func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.snapshotData = nil
            completion?()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .cancelled: self?.connections.removeValue(forKey: id)
            case .failed: connection?.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connections[id]?.cancel() }
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            request.append(data ?? Data())
            guard request.count <= 8192, error == nil else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: request) }
                return
            }
            let valid = WidgetBridge.accepts(text, port: self.listener?.port?.rawValue ?? self.port)
            let body = valid ? self.snapshotData ?? Data() : Data()
            let status = !valid ? "403 Forbidden" : (self.snapshotData == nil ? "204 No Content" : "200 OK")
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
            connection.send(content: Data(header.utf8) + body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
