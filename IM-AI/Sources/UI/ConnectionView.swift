import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var app: AppModel

    private var connected: Bool {
        if case .connected = app.connectionState { return true }
        return false
    }

    private var canEnterChat: Bool {
        connected && !app.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    networkCard

                    Button {
                        app.openChatRoom()
                    } label: {
                        Text("进入聊天室")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEnterChat)

                    if connected && app.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("请先到“我的”页面填写用户名")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .navigationTitle("首页")
            .onAppear {
                app.syncNicknameFromProfile()
                if app.localHostIp.isEmpty { app.refreshLocalIp() }
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "wifi")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("局域网聊天")
                        .font(.title2.weight(.semibold))
                    Text("同一 Wi‑Fi 下点对点 TCP 通信")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ConnectionStatusIndicatorView(state: app.connectionState)
                        .padding(.top, 4)
                }

                Spacer()
            }
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("连接设置")
                    .font(.headline)
                Text("设备 A 启动服务端；设备 B 输入 A 的 IP 连接。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("对方 IP（例如 192.168.1.5）", text: $app.serverIp)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("本机 IP：\(app.localHostIp.isEmpty ? "未知" : app.localHostIp)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { app.refreshLocalIp() }
                        .font(.subheadline)
                }
            }

            HStack(spacing: 12) {
                Button {
                    app.connectToServer()
                } label: {
                    Text("连接")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(connected)

                Button {
                    app.startServer()
                } label: {
                    Text("启动服务端")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(connected)
            }

            Button(role: .destructive) {
                app.disconnect()
            } label: {
                Text("断开连接")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!connected && (app.connectionState != .connecting))
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

