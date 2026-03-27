import SwiftUI

struct ChatRoomsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                if app.chatRooms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                        Text("暂无历史会话")
                            .font(.headline)
                        Text("连接成功后进入聊天室，即会在这里出现。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 30)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(app.chatRooms) { room in
                        Button {
                            app.openHistoryChatRoom(roomId: room.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(room.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(Self.timeLabel(room.updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(room.peerIp)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !room.lastMessagePreview.isEmpty {
                                    Text(room.lastMessagePreview)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                app.deleteHistoryChatRoom(roomId: room.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("聊天室")
        }
    }

    private static func timeLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

