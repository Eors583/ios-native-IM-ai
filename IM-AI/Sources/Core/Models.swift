import Foundation

struct SocketMessage: Codable, Equatable {
    let id: String
    let content: String
    let sender: String
    let timestamp: Int64
    let status: String
    let isSentByMe: Bool
    let messageType: String

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case sender
        case timestamp
        case status
        case isSentByMe = "is_sent_by_me"
        case messageType = "message_type"
    }

    static func heartbeat(sender: String) -> SocketMessage {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return SocketMessage(
            id: "heartbeat_\(now)",
            content: "heartbeat",
            sender: sender,
            timestamp: now,
            status: Constants.statusSent,
            isSentByMe: false,
            messageType: Constants.messageTypeHeartbeat
        )
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

struct Message: Identifiable, Equatable {
    let id: String
    var content: String
    var sender: String
    var timestamp: Date
    var status: MessageStatus
    var isSentByMe: Bool
    var messageType: String
}

struct ChatRoomSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var peerIp: String
    var lastMessagePreview: String
    var createdAt: Date
    var updatedAt: Date
}

extension SocketMessage {
    func toDomain() -> Message {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let parsedStatus = MessageStatus(rawValue: status.lowercased()) ?? .sent
        return Message(
            id: id,
            content: content,
            sender: sender,
            timestamp: date,
            status: parsedStatus,
            isSentByMe: isSentByMe,
            messageType: messageType
        )
    }
}

extension Message {
    func toSocketMessage() -> SocketMessage {
        let ts = Int64(timestamp.timeIntervalSince1970 * 1000)
        return SocketMessage(
            id: id,
            content: content,
            sender: sender,
            timestamp: ts,
            status: status.rawValue.lowercased(),
            isSentByMe: isSentByMe,
            messageType: messageType
        )
    }
}

