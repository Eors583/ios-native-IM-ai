import Foundation
import Network

/// 连接 `apps/android/tools/pc-ai-server/server.py` 的最小客户端（同 SocketMessage 协议）。
final class AiBridgeClient {
    private let queue = DispatchQueue(label: "aiim.ai.bridge.queue")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var connection: NWConnection?
    private var receiveBuffer = Data()

    func connect(host: String, port: UInt16, onState: @escaping (NWConnection.State) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnect()
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
            let conn = NWConnection(to: endpoint, using: .tcp)
            self.connection = conn
            conn.stateUpdateHandler = { state in onState(state) }
            conn.start(queue: self.queue)
            self.startReceiving()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.receiveBuffer = Data()
        }
    }

    func sendText(_ text: String, sender: String) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = SocketMessage(
            id: UUID().uuidString,
            content: text,
            sender: sender,
            timestamp: now,
            status: Constants.statusSent,
            isSentByMe: true,
            messageType: Constants.messageTypeText
        )
        try await send(msg)
    }

    func onMessage(_ handler: @escaping (SocketMessage) -> Void) {
        self.messageHandler = handler
    }

    // MARK: - Private

    private var messageHandler: ((SocketMessage) -> Void)?

    private func send(_ message: SocketMessage) async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self, let conn = self.connection else {
                    cont.resume(throwing: NSError(domain: "AIIM", code: -1, userInfo: [NSLocalizedDescriptionKey: "未连接到 AI 桥"]))
                    return
                }
                do {
                    let data = try self.encoder.encode(message)
                    var framed = data
                    framed.append(0x0A)
                    conn.send(content: framed, completion: .contentProcessed { err in
                        if let err { cont.resume(throwing: err) } else { cont.resume(returning: ()) }
                    })
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.disconnect()
                return
            }
            self.startReceiving()
        }
    }

    private func drain() {
        while true {
            guard let idx = receiveBuffer.firstIndex(of: 0x0A) else { break }
            let line = receiveBuffer.prefix(upTo: idx)
            receiveBuffer.removeSubrange(...idx)
            guard !line.isEmpty else { continue }
            if let msg = try? decoder.decode(SocketMessage.self, from: line) {
                if msg.messageType == Constants.messageTypeHeartbeat { continue }
                messageHandler?(msg)
            }
        }
    }
}

