import Foundation
import Network

struct AiChatMessage: Identifiable, Equatable {
    let id: String
    var content: String
    let fromUser: Bool
}

@MainActor
final class AiChatViewModel: ObservableObject {
    @Published var messages: [AiChatMessage] = []
    @Published var input: String = ""
    @Published var isGenerating: Bool = false
    @Published var error: String? = nil

    // Model picker + download
    @Published var availableModels: [OnDeviceModelOption] = []
    @Published var selectedModelId: String = ""
    @Published var selectedModelDisplayName: String = ""
    @Published var isActiveModelReady: Bool = false

    @Published var modelPickerVisible: Bool = false
    @Published var pickerSelectedModelId: String = ""

    @Published var downloadConfirmVisible: Bool = false
    @Published var pendingDownloadModelId: String? = nil
    @Published var pendingDownloadModelDisplayName: String = ""

    @Published var downloadProgressVisible: Bool = false
    @Published var downloadProgress: ModelDownloadProgressUi? = nil
    @Published var downloadError: String? = nil

    // AI Bridge (PC)
    @Published var bridgeHost: String = ""
    @Published var bridgePort: String = "8080"
    @Published var bridgeStatus: String = "未连接"

    private let modelManager = OnDeviceModelManager()
    private let bridge = AiBridgeClient()

    private var downloadTask: Task<Void, Never>?

    init() {
        refreshModelLabels()
        refreshModelAvailability()

        bridge.onMessage { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                if self.isGenerating {
                    self.isGenerating = false
                }
                self.appendOrSetLastAssistantText(msg.content)
            }
        }
    }

    func refreshModelLabels() {
        let id = modelManager.selectedModelId()
        let name = modelManager.availableModels().first(where: { $0.id == id })?.displayName ?? id
        availableModels = modelManager.availableModels()
        selectedModelId = id
        selectedModelDisplayName = name
    }

    func refreshModelAvailability() {
        isActiveModelReady = modelManager.isActiveModelReady()
    }

    func openModelPicker() {
        let current = selectedModelId.isEmpty ? (availableModels.first?.id ?? "") : selectedModelId
        pickerSelectedModelId = current
        modelPickerVisible = true
    }

    func dismissModelPicker() {
        modelPickerVisible = false
    }

    func confirmModelPickerSelection() {
        let id = pickerSelectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let display = availableModels.first(where: { $0.id == id })?.displayName ?? id
        modelPickerVisible = false
        downloadConfirmVisible = true
        pendingDownloadModelId = id
        pendingDownloadModelDisplayName = display
    }

    func dismissDownloadConfirm() {
        downloadConfirmVisible = false
        pendingDownloadModelId = nil
        pendingDownloadModelDisplayName = ""
    }

    func confirmModelDownload() {
        guard let modelId = pendingDownloadModelId else { return }
        let display = pendingDownloadModelDisplayName
        downloadConfirmVisible = false
        downloadProgressVisible = true
        downloadError = nil
        downloadProgress = .init(modelDisplayName: display, fileLabel: "", overallProgress: 0, stepLabel: "", detail: "")

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await modelManager.downloadAndActivateModel(modelId: modelId, forceRedownload: false) { p in
                Task { @MainActor in
                    self.downloadProgress = self.mapProgress(p, modelDisplayName: display)
                }
            }
            await MainActor.run {
                self.downloadProgressVisible = false
                self.downloadProgress = nil
                self.pendingDownloadModelId = nil
                self.pendingDownloadModelDisplayName = ""
                switch result {
                case .success:
                    self.refreshModelLabels()
                    self.refreshModelAvailability()
                case .failure(let e):
                    self.downloadError = e.localizedDescription
                }
            }
        }
    }

    func cancelModelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgressVisible = false
        downloadProgress = nil
        pendingDownloadModelId = nil
        pendingDownloadModelDisplayName = ""
    }

    func dismissDownloadError() {
        downloadError = nil
    }

    func connectBridge(nickname: String) {
        let host = bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = UInt16(bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8080
        guard !host.isEmpty else {
            error = "请填写电脑（PC AI 桥）的局域网 IP"
            return
        }
        bridgeStatus = "连接中…"
        bridge.connect(host: host, port: port) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.bridgeStatus = "已连接"
                case .failed(let err):
                    self.bridgeStatus = "失败"
                    self.error = err.localizedDescription
                case .cancelled:
                    self.bridgeStatus = "未连接"
                default:
                    break
                }
            }
        }
    }

    func disconnectBridge() {
        bridge.disconnect()
        bridgeStatus = "未连接"
    }

    func send(nickname: String) {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isGenerating else { return }
        error = nil

        let user = AiChatMessage(id: UUID().uuidString, content: q, fromUser: true)
        messages.append(user)
        input = ""

        let aiId = UUID().uuidString
        messages.append(.init(id: aiId, content: "", fromUser: false))
        isGenerating = true

        // 先走 PC AI 桥保证可用；端侧推理等你把 iOS MNN 推理库接入后再切。
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridge.sendText(q, sender: nickname.isEmpty ? "用户" : nickname)
                // 回复会在 onMessage 回调里写入
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.appendOrSetLastAssistantText("生成失败")
                    self.error = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Progress mapping

    private func mapProgress(_ p: ModelDownloadProgress, modelDisplayName: String) -> ModelDownloadProgressUi {
        let fileFraction: Double = {
            if p.skipped { return 1.0 }
            if let total = p.bytesTotal, total > 0 { return Double(p.bytesReceived) / Double(total) }
            return p.bytesReceived > 0 ? 0.35 : 0.0
        }()
        let overall = (Double((p.stepIndex - 1)) + min(max(fileFraction, 0), 1)) / Double(p.stepCount)

        let detail: String = {
            if p.skipped { return "已存在，跳过" }
            if let total = p.bytesTotal, total > 0 {
                return "\(formatBytes(p.bytesReceived)) / \(formatBytes(total))"
            }
            if p.bytesReceived > 0 { return "已下载 \(formatBytes(p.bytesReceived))" }
            return "连接中…"
        }()

        return .init(
            modelDisplayName: modelDisplayName,
            fileLabel: p.fileName,
            overallProgress: Float(min(max(overall, 0), 1)),
            stepLabel: "\(p.stepIndex)/\(p.stepCount)",
            detail: detail
        )
    }

    private func formatBytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024.0)
    }

    private func appendOrSetLastAssistantText(_ text: String) {
        guard let lastIdx = messages.lastIndex(where: { !$0.fromUser }) else {
            messages.append(.init(id: UUID().uuidString, content: text, fromUser: false))
            return
        }
        if messages[lastIdx].content.isEmpty {
            messages[lastIdx].content = text
        } else {
            messages[lastIdx].content += text
        }
    }
}

struct ModelDownloadProgressUi: Equatable {
    let modelDisplayName: String
    let fileLabel: String
    let overallProgress: Float
    let stepLabel: String
    let detail: String
}

