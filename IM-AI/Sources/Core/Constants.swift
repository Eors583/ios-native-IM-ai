import Foundation

enum Constants {
    // Socket
    static let socketPort: UInt16 = 8080
    static let socketTimeoutSeconds: TimeInterval = 15
    static let heartbeatIntervalSeconds: TimeInterval = 30

    // Message types
    static let messageTypeText = "text"
    static let messageTypeHeartbeat = "heartbeat"
    static let messageTypeSystem = "system"
    static let messageTypeDeliveryAck = "delivery_ack"
    static let messageTypeReadAck = "read_ack"

    // Message status (lowercase, same as Android socket JSON)
    static let statusSending = "sending"
    static let statusSent = "sent"
    static let statusDelivered = "delivered"
    static let statusRead = "read"
    static let statusFailed = "failed"

    static let defaultNickname = "匿名用户"
}

