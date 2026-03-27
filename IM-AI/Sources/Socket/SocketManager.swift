import Combine
import Foundation
import Network

final class SocketManager {
    private let queue = DispatchQueue(label: "aiim.socket.queue")
    private let encoder: JSONEncoder = .init()
    private let decoder: JSONDecoder = .init()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var heartbeatTimer: DispatchSourceTimer?

    private var currentNickname: String = Constants.defaultNickname

    private let connectionStateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { connectionStateSubject.eraseToAnyPublisher() }

    private let receivedMessageSubject = CurrentValueSubject<SocketMessage?, Never>(nil)
    var receivedMessagePublisher: AnyPublisher<SocketMessage?, Never> { receivedMessageSubject.eraseToAnyPublisher() }

    func setNickname(_ nickname: String) {
        currentNickname = nickname
    }

    func getNickname() -> String { currentNickname }

    func startServer(port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isBusy else { return }
            self.connectionStateSubject.send(.connecting)

            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener

                listener.newConnectionHandler = { [weak self] newConn in
                    guard let self else { return }
                    self.attachPeer(newConn)
                    self.listener?.cancel()
                    self.listener = nil
                }

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .failed(let err) = state {
                        self.connectionStateSubject.send(.failed(err.localizedDescription))
                        self.cleanupListenerOnly()
                    }
                }

                listener.start(queue: self.queue)
            } catch {
                self.connectionStateSubject.send(.failed(error.localizedDescription))
                self.cleanupListenerOnly()
            }
        }
    }

    func connectToServer(serverIp: String, port: UInt16) {
        let host = serverIp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            connectionStateSubject.send(.failed("IP 地址为空"))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isBusy else { return }
            self.connectionStateSubject.send(.connecting)

            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            let conn = NWConnection(to: endpoint, using: .tcp)

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.attachPeer(conn)
                case .failed(let err):
                    self.connectionStateSubject.send(.failed(err.localizedDescription))
                    self.closePeerQuietly()
                case .cancelled:
                    self.connectionStateSubject.send(.disconnected)
                default:
                    break
                }
            }

            conn.start(queue: self.queue)

            // Best-effort connect timeout: if still connecting after timeout, cancel.
            self.queue.asyncAfter(deadline: .now() + Constants.socketTimeoutSeconds) { [weak self] in
                guard let self else { return }
                if case .connecting = self.connectionStateSubject.value {
                    conn.cancel()
                    self.connectionStateSubject.send(.failed("连接超时"))
                }
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopHeartbeat()
            self.receiveBuffer = Data()
            self.listener?.cancel()
            self.listener = nil
            self.connection?.cancel()
            self.connection = nil
            self.connectionStateSubject.send(.disconnected)
        }
    }

    func sendMessage(_ message: SocketMessage) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard let conn = self.connection else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    let data = try self.encoder.encode(message)
                    var framed = data
                    framed.append(0x0A) // '\n'
                    conn.send(content: framed, completion: .contentProcessed { err in
                        continuation.resume(returning: err == nil)
                    })
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func enqueueSend(_ message: SocketMessage) {
        Task { _ = await sendMessage(message) }
    }

    // MARK: - Internal

    private var isBusy: Bool {
        switch connectionStateSubject.value {
        case .connected, .connecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    private func attachPeer(_ conn: NWConnection) {
        closePeerQuietly()
        connection = conn
        connectionStateSubject.send(.connected)
        startReceiving()
        startHeartbeat()
    }

    private func closePeerQuietly() {
        stopHeartbeat()
        connection?.cancel()
        connection = nil
    }

    private func cleanupListenerOnly() {
        listener?.cancel()
        listener = nil
    }

    private func startReceiving() {
        guard let conn = connection else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainReceiveBuffer()
            }

            if isComplete || error != nil {
                self.connectionStateSubject.send(.disconnected)
                self.closePeerQuietly()
                self.cleanupListenerOnly()
                return
            }

            self.startReceiving()
        }
    }

    private func drainReceiveBuffer() {
        while true {
            guard let idx = receiveBuffer.firstIndex(of: 0x0A) else { break } // '\n'
            let lineData = receiveBuffer.prefix(upTo: idx)
            receiveBuffer.removeSubrange(...idx)
            guard !lineData.isEmpty else { continue }
            processIncomingLine(lineData)
        }
    }

    private func processIncomingLine(_ data: Data) {
        do {
            let msg = try decoder.decode(SocketMessage.self, from: data)
            if msg.messageType == Constants.messageTypeHeartbeat {
                return
            }
            receivedMessageSubject.send(msg)
        } catch {
            // Ignore malformed frames to stay resilient.
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Constants.heartbeatIntervalSeconds, repeating: Constants.heartbeatIntervalSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.connection != nil else { return }
            self.enqueueSend(.heartbeat(sender: self.currentNickname))
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

