import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let socket: SocketManager
    let store: ChatStore
    let profile: UserProfileStore

    @Published var selectedTab: BottomTab = .home
    @Published var mainScreen: MainScreen = .connection

    /// Connection screen inputs
    @Published var serverIp: String = ""
    @Published var localHostIp: String = ""
    @Published var nickname: String = ""

    /// Chat input
    @Published var messageInput: String = ""

    /// UI state
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var messages: [Message] = []
    @Published private(set) var chatRooms: [ChatRoomSummary] = []
    @Published var errorMessage: String? = nil

    private var cancellables: Set<AnyCancellable> = []

    private var activeRoomId: String = ""
    private var lastReadReceiptAnchorId: String? = nil

    /// 默认初始化必须在 MainActor 上创建依赖，不能用默认参数（默认参数会在非隔离上下文计算）。
    init() {
        self.socket = SocketManager()
        self.store = ChatStore()
        self.profile = UserProfileStore()

        nickname = profile.load().username.trimmingCharacters(in: .whitespacesAndNewlines)
        localHostIp = NetworkInfo.localIPv4Address() ?? ""

        bindStreams()
    }

    init(
        socket: SocketManager,
        store: ChatStore,
        profile: UserProfileStore
    ) {
        self.socket = socket
        self.store = store
        self.profile = profile

        nickname = profile.load().username.trimmingCharacters(in: .whitespacesAndNewlines)
        localHostIp = NetworkInfo.localIPv4Address() ?? ""

        bindStreams()
    }

    private func bindStreams() {
        socket.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.connectionState = state
                if case .connected = state {
                    let nick = self.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !nick.isEmpty { self.socket.setNickname(nick) }
                }
                if case .disconnected = state {
                    self.mainScreen = .connection
                }
                if case .failed(let err) = state {
                    self.mainScreen = .connection
                    self.errorMessage = err
                }
            }
            .store(in: &cancellables)

        socket.receivedMessagePublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] socketMessage in
                guard let self else { return }
                Task { await self.onSocketMessageReceived(socketMessage) }
            }
            .store(in: &cancellables)

        store.chatRoomsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rooms in self?.chatRooms = rooms }
            .store(in: &cancellables)

        store.messagesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msgs in self?.messages = msgs }
            .store(in: &cancellables)
    }

    func refreshLocalIp() {
        localHostIp = NetworkInfo.localIPv4Address() ?? ""
    }

    func syncNicknameFromProfile() {
        nickname = profile.load().username.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .connected = connectionState, !nickname.isEmpty {
            socket.setNickname(nickname)
        }
    }

    func connectToServer() {
        errorMessage = nil
        let host = serverIp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMessage = "请输入对方手机的 IP 地址"
            return
        }
        guard NetworkInfo.isValidIPv4(host) else {
            errorMessage = "IP 格式不正确，请填类似 192.168.1.5 的四段数字"
            return
        }
        socket.connectToServer(serverIp: host, port: Constants.socketPort)
    }

    func startServer() {
        errorMessage = nil
        socket.startServer(port: Constants.socketPort)
    }

    func disconnect() {
        socket.disconnect()
    }

    func openChatRoom() {
        guard case .connected = connectionState else { return }
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if nick.isEmpty {
            errorMessage = "请先在我的页面填写用户名"
            return
        }

        let peerIp = serverIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localHostIp.trimmingCharacters(in: .whitespacesAndNewlines)
            : serverIp.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            lastReadReceiptAnchorId = nil
            activeRoomId = await store.createChatRoom(peerIp: peerIp)
            socket.setNickname(nick)
            mainScreen = .chatRoom
        }
    }

    func openHistoryChatRoom(roomId: String) {
        lastReadReceiptAnchorId = nil
        activeRoomId = roomId
        store.setActiveRoom(roomId: roomId)
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { socket.setNickname(nick) }
        mainScreen = .chatRoom
    }

    func deleteHistoryChatRoom(roomId: String) {
        Task { await store.deleteChatRoom(roomId: roomId) }
        if activeRoomId == roomId { activeRoomId = "" }
    }

    func backToConnection() {
        lastReadReceiptAnchorId = nil
        mainScreen = .connection
    }

    func sendMessage() {
        let content = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !nick.isEmpty else { return }
        Task { await sendMessageWithContent(rawContent: messageInput) }
    }

    func sendMessageWithContent(rawContent: String) async {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !nick.isEmpty else {
            errorMessage = "内容或昵称为空"
            return
        }
        do {
            try await store.sendMessage(
                content: content,
                sender: nick,
                roomId: activeRoomId,
                socket: socket
            )
            messageInput = ""
        } catch {
            errorMessage = "发送失败: \(error.localizedDescription)"
        }
    }

    func acknowledgePeerMessagesReadIfNeeded() {
        guard case .connected = connectionState else { return }
        let anchor = messages.last(where: { !$0.isSentByMe && $0.messageType == Constants.messageTypeText })
        guard let anchor else { return }
        if anchor.id == lastReadReceiptAnchorId { return }
        lastReadReceiptAnchorId = anchor.id
        Task {
            do {
                try await store.sendReadReceipt(anchorMessageId: anchor.id, roomId: activeRoomId, socket: socket)
            } catch {
                lastReadReceiptAnchorId = nil
            }
        }
    }

    // MARK: - Socket inbound

    private func onSocketMessageReceived(_ socketMessage: SocketMessage) async {
        switch socketMessage.messageType {
        case Constants.messageTypeDeliveryAck:
            await store.handleDeliveryAck(messageId: socketMessage.content.trimmingCharacters(in: .whitespacesAndNewlines), roomId: activeRoomId)
            return
        case Constants.messageTypeReadAck:
            await store.handleReadAck(anchorMessageId: socketMessage.content.trimmingCharacters(in: .whitespacesAndNewlines), roomId: activeRoomId)
            return
        default:
            break
        }

        guard !activeRoomId.isEmpty else { return }

        var domain = socketMessage.toDomain()
        domain.isSentByMe = false
        await store.insertIncomingMessage(domain, roomId: activeRoomId)

        if socketMessage.messageType == Constants.messageTypeText {
            await store.sendDeliveryAck(remoteMessageId: socketMessage.id, socket: socket)
        }
    }
}

enum BottomTab: Hashable {
    case home
    case chatRooms
    case ai
    case profile
}

enum MainScreen {
    case connection
    case chatRoom
}

