import Combine
import Foundation
import SQLite3

@MainActor
final class ChatStore {
    private let dbQueue = DispatchQueue(label: "aiim.chatstore.db")
    private let db: SQLiteDB

    private let messagesSubject = CurrentValueSubject<[Message], Never>([])
    var messagesPublisher: AnyPublisher<[Message], Never> { messagesSubject.eraseToAnyPublisher() }

    private let roomsSubject = CurrentValueSubject<[ChatRoomSummary], Never>([])
    var chatRoomsPublisher: AnyPublisher<[ChatRoomSummary], Never> { roomsSubject.eraseToAnyPublisher() }

    private var activeRoomId: String = ""

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("aiim_chat.sqlite").path
        db = try! SQLiteDB(path: path)
        try! migrate()
        reloadRooms()
    }

    func setActiveRoom(roomId: String) {
        activeRoomId = roomId
        reloadMessages(roomId: roomId)
    }

    func createChatRoom(peerIp: String) async -> String {
        let now = Date()
        let roomId = UUID().uuidString
        let title = "聊天室 \(Self.formatRoomTitleDate(now))"
        await dbAsync {
            let sql = """
            INSERT OR REPLACE INTO chat_rooms (id, title, peer_ip, last_message_preview, created_at_ms, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            let stmt = try self.db.prepare(sql)
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, roomId)
            try self.db.bindText(stmt, 2, title)
            try self.db.bindText(stmt, 3, peerIp)
            try self.db.bindText(stmt, 4, "")
            let ms = Int64(now.timeIntervalSince1970 * 1000)
            try self.db.bindInt64(stmt, 5, ms)
            try self.db.bindInt64(stmt, 6, ms)
            _ = try self.db.step(stmt)
        }
        activeRoomId = roomId
        reloadRooms()
        reloadMessages(roomId: roomId)
        return roomId
    }

    func deleteChatRoom(roomId: String) async {
        await dbAsync {
            let delMsgs = try self.db.prepare("DELETE FROM messages WHERE room_id = ?;")
            defer { self.db.finalize(delMsgs) }
            try self.db.bindText(delMsgs, 1, roomId)
            _ = try self.db.step(delMsgs)

            let delRoom = try self.db.prepare("DELETE FROM chat_rooms WHERE id = ?;")
            defer { self.db.finalize(delRoom) }
            try self.db.bindText(delRoom, 1, roomId)
            _ = try self.db.step(delRoom)
        }
        if activeRoomId == roomId { activeRoomId = "" }
        reloadRooms()
        if !activeRoomId.isEmpty { reloadMessages(roomId: activeRoomId) } else { messagesSubject.send([]) }
    }

    func sendMessage(content: String, sender: String, roomId: String, socket: SocketManager) async throws {
        if roomId.isEmpty { throw NSError(domain: "AIIM", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前未选择聊天室"]) }
        var message = Message(
            id: UUID().uuidString,
            content: content,
            sender: sender,
            timestamp: Date(),
            status: .sending,
            isSentByMe: true,
            messageType: Constants.messageTypeText
        )
        await insertMessage(message, roomId: roomId)
        await touchRoomByMessage(roomId: roomId, message: content)

        let ok = await socket.sendMessage(message.toSocketMessage())
        message.status = ok ? .sent : .failed
        await updateMessageStatus(messageId: message.id, roomId: roomId, status: message.status)
        reloadMessages(roomId: roomId)
    }

    func insertIncomingMessage(_ message: Message, roomId: String) async {
        await insertMessage(message, roomId: roomId)
        await touchRoomByMessage(roomId: roomId, message: message.content)
        reloadMessages(roomId: roomId)
    }

    func sendDeliveryAck(remoteMessageId: String, socket: SocketManager) async {
        guard !remoteMessageId.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ack = SocketMessage(
            id: UUID().uuidString,
            content: remoteMessageId,
            sender: socket.getNickname(),
            timestamp: now,
            status: Constants.statusSent,
            isSentByMe: false,
            messageType: Constants.messageTypeDeliveryAck
        )
        _ = await socket.sendMessage(ack)
    }

    func sendReadReceipt(anchorMessageId: String, roomId: String, socket: SocketManager) async throws {
        let trimmed = anchorMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        if roomId.isEmpty { return }
        let anchor = await getMessageById(trimmed)
        guard let anchor, anchor.roomId == roomId else { return }
        if anchor.isSentByMe { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ack = SocketMessage(
            id: UUID().uuidString,
            content: trimmed,
            sender: socket.getNickname(),
            timestamp: now,
            status: Constants.statusSent,
            isSentByMe: false,
            messageType: Constants.messageTypeReadAck
        )
        _ = await socket.sendMessage(ack)
    }

    func handleDeliveryAck(messageId: String, roomId: String) async {
        if messageId.isEmpty || roomId.isEmpty { return }
        guard let entity = await getMessageById(messageId), entity.roomId == roomId else { return }
        if entity.isSentByMe == false { return }
        let current = MessageStatus(rawValue: entity.status.lowercased()) ?? .sent
        let next: MessageStatus = (current == .read) ? .read : .delivered
        await updateMessageStatus(messageId: messageId, roomId: roomId, status: next)
        reloadMessages(roomId: roomId)
    }

    func handleReadAck(anchorMessageId: String, roomId: String) async {
        if anchorMessageId.isEmpty || roomId.isEmpty { return }
        guard let anchor = await getMessageById(anchorMessageId), anchor.roomId == roomId else { return }
        if anchor.isSentByMe { return }
        await markMyMessagesReadUpTo(roomId: roomId, beforeInclusive: anchor.timestampMs)
        reloadMessages(roomId: roomId)
    }

    // MARK: - Private DB

    private func migrate() throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS chat_rooms (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              peer_ip TEXT NOT NULL,
              last_message_preview TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY NOT NULL,
              content TEXT NOT NULL,
              sender TEXT NOT NULL,
              timestamp_ms INTEGER NOT NULL,
              status TEXT NOT NULL,
              is_sent_by_me INTEGER NOT NULL,
              message_type TEXT NOT NULL,
              room_id TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL
            );
            """
        )
        try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_room_ts ON messages(room_id, timestamp_ms);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_rooms_updated ON chat_rooms(updated_at_ms);")
    }

    private func insertMessage(_ message: Message, roomId: String) async {
        await dbAsync {
            let sql = """
            INSERT OR REPLACE INTO messages
            (id, content, sender, timestamp_ms, status, is_sent_by_me, message_type, room_id, created_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try self.db.prepare(sql)
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, message.id)
            try self.db.bindText(stmt, 2, message.content)
            try self.db.bindText(stmt, 3, message.sender)
            try self.db.bindInt64(stmt, 4, Int64(message.timestamp.timeIntervalSince1970 * 1000))
            try self.db.bindText(stmt, 5, message.status.rawValue.uppercased())
            try self.db.bindInt(stmt, 6, message.isSentByMe ? 1 : 0)
            try self.db.bindText(stmt, 7, message.messageType)
            try self.db.bindText(stmt, 8, roomId)
            try self.db.bindInt64(stmt, 9, Int64(Date().timeIntervalSince1970 * 1000))
            _ = try self.db.step(stmt)
        }
    }

    private func updateMessageStatus(messageId: String, roomId: String, status: MessageStatus) async {
        await dbAsync {
            let sql = "UPDATE messages SET status = ? WHERE id = ? AND room_id = ?;"
            let stmt = try self.db.prepare(sql)
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, status.rawValue.uppercased())
            try self.db.bindText(stmt, 2, messageId)
            try self.db.bindText(stmt, 3, roomId)
            _ = try self.db.step(stmt)
        }
    }

    private func touchRoomByMessage(roomId: String, message: String) async {
        await dbAsync {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let preview = String(message.prefix(60))
            let stmt = try self.db.prepare("UPDATE chat_rooms SET last_message_preview = ?, updated_at_ms = ? WHERE id = ?;")
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, preview)
            try self.db.bindInt64(stmt, 2, nowMs)
            try self.db.bindText(stmt, 3, roomId)
            _ = try self.db.step(stmt)
        }
        reloadRooms()
    }

    private func markMyMessagesReadUpTo(roomId: String, beforeInclusive: Int64) async {
        await dbAsync {
            let sql = """
            UPDATE messages SET status = ?
            WHERE room_id = ?
              AND is_sent_by_me = 1
              AND timestamp_ms <= ?
              AND status != 'FAILED';
            """
            let stmt = try self.db.prepare(sql)
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, MessageStatus.read.rawValue.uppercased())
            try self.db.bindText(stmt, 2, roomId)
            try self.db.bindInt64(stmt, 3, beforeInclusive)
            _ = try self.db.step(stmt)
        }
    }

    private func reloadRooms() {
        Task {
            let rooms = await fetchRooms()
            roomsSubject.send(rooms)
        }
    }

    private func reloadMessages(roomId: String) {
        Task {
            let msgs = await fetchMessages(roomId: roomId)
            messagesSubject.send(msgs)
        }
    }

    private func fetchRooms() async -> [ChatRoomSummary] {
        await dbAsyncReturn {
            var rooms: [ChatRoomSummary] = []
            let stmt = try self.db.prepare(
                "SELECT id, title, peer_ip, last_message_preview, created_at_ms, updated_at_ms FROM chat_rooms ORDER BY updated_at_ms DESC;"
            )
            defer { self.db.finalize(stmt) }
            while try self.db.step(stmt) == SQLITE_ROW {
                let id = self.db.colText(stmt, 0)
                let title = self.db.colText(stmt, 1)
                let peerIp = self.db.colText(stmt, 2)
                let preview = self.db.colText(stmt, 3)
                let createdMs = self.db.colInt64(stmt, 4)
                let updatedMs = self.db.colInt64(stmt, 5)
                rooms.append(
                    ChatRoomSummary(
                        id: id,
                        title: title,
                        peerIp: peerIp,
                        lastMessagePreview: preview,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000),
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000)
                    )
                )
            }
            return rooms
        } ?? []
    }

    private func fetchMessages(roomId: String) async -> [Message] {
        await dbAsyncReturn {
            var msgs: [Message] = []
            let stmt = try self.db.prepare(
                "SELECT id, content, sender, timestamp_ms, status, is_sent_by_me, message_type FROM messages WHERE room_id = ? ORDER BY timestamp_ms ASC;"
            )
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, roomId)
            while try self.db.step(stmt) == SQLITE_ROW {
                let id = self.db.colText(stmt, 0)
                let content = self.db.colText(stmt, 1)
                let sender = self.db.colText(stmt, 2)
                let ts = self.db.colInt64(stmt, 3)
                let statusRaw = self.db.colText(stmt, 4)
                let isMe = self.db.colInt(stmt, 5) == 1
                let type = self.db.colText(stmt, 6)
                let parsed = MessageStatus(rawValue: statusRaw.lowercased()) ?? {
                    // Android stores enum name (SENT/FAILED...), iOS uses same.
                    switch statusRaw.uppercased() {
                    case "SENDING": return .sending
                    case "SENT": return .sent
                    case "DELIVERED": return .delivered
                    case "READ": return .read
                    case "FAILED": return .failed
                    default: return .sent
                    }
                }()
                msgs.append(
                    Message(
                        id: id,
                        content: content,
                        sender: sender,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000),
                        status: parsed,
                        isSentByMe: isMe,
                        messageType: type
                    )
                )
            }
            return msgs
        } ?? []
    }

    private func getMessageById(_ id: String) async -> MessageRow? {
        await dbAsyncReturn {
            let stmt = try self.db.prepare(
                "SELECT id, room_id, timestamp_ms, is_sent_by_me, status FROM messages WHERE id = ? LIMIT 1;"
            )
            defer { self.db.finalize(stmt) }
            try self.db.bindText(stmt, 1, id)
            guard try self.db.step(stmt) == SQLITE_ROW else {
                throw SQLiteError.step("row not found")
            }
            return MessageRow(
                id: self.db.colText(stmt, 0),
                roomId: self.db.colText(stmt, 1),
                timestampMs: self.db.colInt64(stmt, 2),
                isSentByMe: self.db.colInt(stmt, 3) == 1,
                status: self.db.colText(stmt, 4)
            )
        }
    }

    private struct MessageRow {
        let id: String
        let roomId: String
        let timestampMs: Int64
        let isSentByMe: Bool
        let status: String
    }

    private func dbAsync(_ work: @escaping () throws -> Void) async {
        await withCheckedContinuation { cont in
            dbQueue.async {
                do { try work() } catch { }
                cont.resume()
            }
        }
    }

    private func dbAsyncReturn<T>(_ work: @escaping () throws -> T) async -> T? {
        await withCheckedContinuation { cont in
            dbQueue.async {
                do {
                    cont.resume(returning: try work())
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func formatRoomTitleDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

