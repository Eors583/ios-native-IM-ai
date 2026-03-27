import SwiftUI

struct ChatRoomView: View {
    @EnvironmentObject private var app: AppModel
    @State private var scrollAnchor = UUID()

    private var isConnected: Bool {
        if case .connected = app.connectionState { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                messageList
                inputBar
            }
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
            .onChange(of: app.messages.count) { _, _ in
                app.acknowledgePeerMessagesReadIfNeeded()
            }
            .onAppear {
                app.acknowledgePeerMessagesReadIfNeeded()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                app.backToConnection()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("聊天室")
                    .font(.headline)
                Text("以 \(app.nickname.trimmingCharacters(in: .whitespacesAndNewlines)) 发送")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            ConnectionStatusIndicatorView(state: app.connectionState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if app.messages.isEmpty {
                        emptyState
                            .padding(.top, 40)
                    } else {
                        ForEach(app.messages) { msg in
                            MessageBubbleView(message: msg)
                                .id(msg.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(scrollAnchor)
                }
                .padding(.vertical, 12)
            }
            .onChange(of: app.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(scrollAnchor, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 88, height: 88)
                .overlay(
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )
            Text("还没有消息")
                .font(.headline)
            Text("试着发送一条文本消息吧。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var inputBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("输入消息…", text: $app.messageInput, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                Button {
                    app.sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected || app.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

private struct MessageBubbleView: View {
    let message: Message

    private var bubbleColor: Color {
        message.isSentByMe ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemBackground)
    }

    private var border: Color? {
        message.isSentByMe ? nil : Color(uiColor: .separator).opacity(0.4)
    }

    private var alignment: HorizontalAlignment {
        message.isSentByMe ? .trailing : .leading
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                if !message.isSentByMe && message.messageType != Constants.messageTypeSystem {
                    Text(message.sender)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }

                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    if message.isSentByMe {
                        Text(statusLabel(message.status))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor(message.status))
                    } else {
                        Spacer().frame(width: 1)
                    }
                    Spacer()
                    Text(timeLabel(message.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(bubbleColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
            .frame(maxWidth: 520, alignment: message.isSentByMe ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: message.isSentByMe ? .trailing : .leading)

            if message.messageType == Constants.messageTypeSystem {
                Text(message.content)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: message.isSentByMe ? .trailing : .center)
                    .padding(.vertical, 6)
            }
        }
    }

    private func statusLabel(_ status: MessageStatus) -> String {
        switch status {
        case .sending: return "发送中"
        case .sent: return "已发送"
        case .delivered: return "已送达"
        case .read: return "已读"
        case .failed: return "失败"
        }
    }

    private func statusColor(_ status: MessageStatus) -> Color {
        switch status {
        case .sending: return .secondary
        case .sent: return Color.accentColor
        case .delivered: return Color(red: 0.02, green: 0.59, blue: 0.41) // #059669
        case .read: return Color(red: 0.01, green: 0.41, blue: 0.63) // #0369A1
        case .failed: return .red
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

