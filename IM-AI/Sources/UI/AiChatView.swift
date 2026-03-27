import SwiftUI
import Combine
// 不需要 UTType；下载 URL 直接字符串拼接即可

struct AiChatView: View {
    @StateObject private var vm = EmbeddedAiChatViewModel()

    var body: some View {
        NavigationStack { content }
            .navigationTitle("AI聊天")
            .confirmationDialog("切换模型", isPresented: $vm.modelPickerVisible, titleVisibility: .visible) {
                ForEach(vm.availableModels) { opt in
                    Button {
                        vm.pickerSelectedModelId = opt.id
                        vm.confirmModelPickerSelection()
                    } label: {
                        Text(opt.displayName)
                    }
                }
                Button(role: .cancel) { } label: {
                    Text("取消")
                }
            }
            .alert("下载模型", isPresented: $vm.downloadConfirmVisible) {
                Button("下载") { vm.confirmModelDownload() }
                Button("取消", role: .cancel) { vm.dismissDownloadConfirm() }
            } message: {
                Text("将下载模型：\(vm.pendingDownloadModelDisplayName)")
            }
            .alert("下载失败", isPresented: downloadErrorPresented) {
                Button("知道了", role: .cancel) { vm.dismissDownloadError() }
            } message: {
                Text(vm.downloadError ?? "")
            }
            .overlay { downloadOverlay }
    }

    private var content: some View {
        VStack(spacing: 10) {
            modelNotReadyBanner
            modelHeader
            Divider()
            chatList
            errorBanner
            inputBar
        }
    }

    private var modelNotReadyBanner: some View {
        Group {
            if !vm.isActiveModelReady {
                Text("当前没有可用的本地模型，请先下载模型。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
    }

    private var modelHeader: some View {
        HStack {
            Text("当前模型：\(vm.selectedModelDisplayName.isEmpty ? vm.selectedModelId : vm.selectedModelDisplayName)")
                .font(.subheadline)
            Spacer()
            Button("切换模型") { vm.openModelPicker() }
                .buttonStyle(.bordered)
                .disabled(vm.isGenerating || vm.downloadProgressVisible)
        }
        .padding(.horizontal, 12)
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.messages) { msg in
                        chatRow(msg)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: vm.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func chatRow(_ msg: EmbeddedAiChatViewModel.AiChatMessage) -> some View {
        HStack {
            if msg.fromUser { Spacer() }
            Text(msg.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(msg.fromUser ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !msg.fromUser { Spacer() }
        }
        .padding(.horizontal, 12)
    }

    private var errorBanner: some View {
        Group {
            if let err = vm.error {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入问题…", text: $vm.input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.downloadProgressVisible)
            Button("发送") { vm.send() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isGenerating || vm.downloadProgressVisible)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var downloadErrorPresented: Binding<Bool> {
        Binding(
            get: { vm.downloadError != nil },
            set: { if !$0 { vm.dismissDownloadError() } }
        )
    }

    @ViewBuilder
    private var downloadOverlay: some View {
        if vm.downloadProgressVisible, let p = vm.downloadProgress {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("正在下载模型")
                        .font(.headline)
                    Text("模型：\(p.modelDisplayName)")
                        .font(.subheadline)
                    Text("文件：\(p.fileLabel)（\(p.stepLabel)）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ProgressView(value: p.overallProgress)
                        .frame(maxWidth: 280)
                    Text(p.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("取消下载", role: .destructive) { vm.cancelModelDownload() }
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Embedded AI (避免 Target Membership 未勾选导致找不到类型)

@MainActor
final class EmbeddedAiChatViewModel: ObservableObject {
    struct AiChatMessage: Identifiable, Equatable {
        let id: String
        var content: String
        let fromUser: Bool
    }

    struct OnDeviceModelOption: Identifiable, Equatable {
        let id: String
        let displayName: String
    }

    struct ModelDownloadProgress: Equatable {
        let fileName: String
        let stepIndex: Int
        let stepCount: Int
        let bytesReceived: Int64
        let bytesTotal: Int64?
        let skipped: Bool
    }

    struct ModelDownloadProgressUi: Equatable {
        let modelDisplayName: String
        let fileLabel: String
        let overallProgress: Float
        let stepLabel: String
        let detail: String
    }

    @Published var messages: [AiChatMessage] = []
    @Published var input: String = ""
    @Published var isGenerating: Bool = false
    @Published var error: String? = nil

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

    private let modelManager = EmbeddedOnDeviceModelManager()
    private var downloadTask: Task<Void, Never>?

    private var llmEngine: MnnOnDeviceLlmEngine?
    private var llmEngineModelId: String?

    init() {
        refreshModelLabels()
        refreshModelAvailability()

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

    func dismissDownloadConfirm() {
        downloadConfirmVisible = false
        pendingDownloadModelId = nil
        pendingDownloadModelDisplayName = ""
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

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isGenerating else { return }
        error = nil

        messages.append(.init(id: UUID().uuidString, content: q, fromUser: true))
        input = ""

        let aiId = UUID().uuidString
        messages.append(.init(id: aiId, content: "", fromUser: false))
        isGenerating = true

        Task { @MainActor in
            defer { self.isGenerating = false }
            if !self.modelManager.isActiveModelReady() {
                self.appendOrSetLastAssistantText("请先下载本地模型后再提问。")
                return
            }
            let modelId = self.modelManager.selectedModelId()
            let modelDir = self.modelManager.activeModelDirectoryURL()
            do {
                if self.llmEngineModelId != modelId {
                    self.llmEngine?.cancelGeneration()
                    self.llmEngine = nil
                    self.llmEngineModelId = nil
                    let engine = MnnOnDeviceLlmEngine(modelDirectory: modelDir)
                    try await engine.load()
                    self.llmEngine = engine
                    self.llmEngineModelId = modelId
                }
                guard let engine = self.llmEngine else {
                    self.appendOrSetLastAssistantText("无法初始化端侧推理引擎。")
                    return
                }
                let prompt = Self.buildPromptWithSoul(userQuestion: q)
                await engine.streamAnswer(prompt: prompt) { token in
                    self.appendOrSetLastAssistantText(token)
                }
            } catch {
                self.error = error.localizedDescription
                self.appendOrSetLastAssistantText("推理失败：\(error.localizedDescription)")
            }
        }
    }

    /// 与 Android `MnnOnDeviceQaEngine.buildPromptWithSoul` 对齐。
    private static func buildPromptWithSoul(userQuestion: String) -> String {
        let q = userQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "" }
        return soulGentleGirl + "\n\n用户：" + q + "\n助手："
    }

    private static let soulGentleGirl = [
        "你是一个温柔、耐心、细腻的女生助理。",
        "你会用友好、让人安心的语气回答，先共情再给结论；表达简洁、不说教、不冷漠。",
        "你会主动澄清用户意图，但不要连续追问；能一步一步带着用户做。",
        "避免粗鲁、攻击性、阴阳怪气；不要使用过度卖萌或大量表情。"
    ].joined(separator: "\n")

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

// MARK: - Embedded model manager (download only)

@MainActor
final class EmbeddedOnDeviceModelManager {
    private let defaults = UserDefaults.standard
    private let selectedKey = "aiim_ondevice_llm.selected_model_id"
    private let modelBaseOverrideKey = "aiim_ondevice_llm.model_base_url"
    private let defaultModelBase = "https://oss-mnn.obs.cn-south-1.myhuaweicloud.com/mnn"
    private let defaultModelId = "qwen3.5"

    func availableModels() -> [EmbeddedAiChatViewModel.OnDeviceModelOption] {
        [.init(id: "qwen3.5", displayName: "Qwen 3.5")]
    }

    func selectedModelId() -> String {
        (defaults.string(forKey: selectedKey) ?? defaultModelId).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isActiveModelReady() -> Bool {
        isModelReady(modelId: selectedModelId())
    }

    func activeModelDirectoryURL() -> URL {
        modelStorageDir(modelId: selectedModelId())
    }

    func isModelReady(modelId: String) -> Bool {
        let dir = modelStorageDir(modelId: modelId)
        let config = dir.appendingPathComponent("config.json")
        guard fileOk(config) else { return false }
        let names = runtimeModelFileNames(modelDir: dir)
        return fileOk(dir.appendingPathComponent(names.llmModel)) &&
            fileOk(dir.appendingPathComponent(names.llmWeight)) &&
            fileOk(dir.appendingPathComponent("tokenizer.txt"))
    }

    func downloadAndActivateModel(
        modelId: String,
        forceRedownload: Bool,
        onProgress: @escaping (EmbeddedAiChatViewModel.ModelDownloadProgress) -> Void
    ) async -> Result<Void, Error> {
        do {
            try await syncModelFromOss(modelId: modelId, forceRedownload: forceRedownload, onProgress: onProgress)
            defaults.set(modelId, forKey: selectedKey)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func modelStorageDir(modelId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("mnn/\(modelId)", isDirectory: true)
    }

    private func ossBaseUrl(modelId: String) -> URL {
        // 与 Android 一致：base + "/" + modelId
        let base = resolvedModelBaseUrl().absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = modelId.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(id)")!
    }

    private func resolvedModelBaseUrl() -> URL {
        if let fromDefaults = defaults.string(forKey: modelBaseOverrideKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromDefaults.isEmpty,
           let u = URL(string: fromDefaults) {
            return u
        }
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "AIIM_MODEL_BASE_URL") as? String,
           !fromPlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let u = URL(string: fromPlist) {
            return u
        }
        return URL(string: defaultModelBase)!
    }

    private func syncModelFromOss(
        modelId: String,
        forceRedownload: Bool,
        onProgress: @escaping (EmbeddedAiChatViewModel.ModelDownloadProgress) -> Void
    ) async throws {
        let modelDir = modelStorageDir(modelId: modelId)
        if forceRedownload { try? FileManager.default.removeItem(at: modelDir) }
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let base = ossBaseUrl(modelId: modelId)
        let optionalFiles = ["llm_config.json", "configuration.json", "llm.mnn.json", "visual.mnn", "visual.mnn.weight"]
        let stepCount = 1 + 2 + 1 + optionalFiles.count

        func report(_ file: String, _ idx: Int, _ received: Int64, _ total: Int64?, _ skipped: Bool) {
            onProgress(.init(
                fileName: file,
                stepIndex: idx,
                stepCount: stepCount,
                bytesReceived: received,
                bytesTotal: total,
                skipped: skipped
            ))
        }

        let configDest = modelDir.appendingPathComponent("config.json")
        if !forceRedownload, fileOk(configDest) {
            report("config.json", 1, 0, nil, true)
        } else {
            _ = try await downloadFile(from: base.appendingPathComponent("config.json"), to: configDest, required: true) { r, t in
                report("config.json", 1, r, t, false)
            }
        }

        let names = runtimeModelFileNames(modelDir: modelDir)
        let llmDest = modelDir.appendingPathComponent(names.llmModel)
        if !forceRedownload, fileOk(llmDest) {
            report(names.llmModel, 2, 0, nil, true)
        } else {
            _ = try await downloadFile(from: base.appendingPathComponent(names.llmModel), to: llmDest, required: true) { r, t in
                report(names.llmModel, 2, r, t, false)
            }
        }

        let weightDest = modelDir.appendingPathComponent(names.llmWeight)
        if !forceRedownload, fileOk(weightDest) {
            report(names.llmWeight, 3, 0, nil, true)
        } else {
            _ = try await downloadFile(from: base.appendingPathComponent(names.llmWeight), to: weightDest, required: true) { r, t in
                report(names.llmWeight, 3, r, t, false)
            }
        }

        let tokDest = modelDir.appendingPathComponent("tokenizer.txt")
        if !forceRedownload, fileOk(tokDest) {
            report("tokenizer.txt", 4, 0, nil, true)
        } else {
            _ = try await downloadFile(from: base.appendingPathComponent("tokenizer.txt"), to: tokDest, required: true) { r, t in
                report("tokenizer.txt", 4, r, t, false)
            }
        }

        for (i, name) in optionalFiles.enumerated() {
            let stepIndex = 5 + i
            let dest = modelDir.appendingPathComponent(name)
            if !forceRedownload, fileOk(dest) {
                report(name, stepIndex, 0, nil, true)
                continue
            }
            let ok = try await downloadFile(from: base.appendingPathComponent(name), to: dest, required: false) { r, t in
                report(name, stepIndex, r, t, false)
            }
            if !ok {
                report(name, stepIndex, 0, nil, true)
            }
        }
    }

    private func runtimeModelFileNames(modelDir: URL) -> (llmModel: String, llmWeight: String) {
        let config = modelDir.appendingPathComponent("config.json")
        let defaultModel = "llm.mnn"
        let defaultWeight = "llm.mnn.weight"
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (defaultModel, defaultWeight)
        }
        let m = (obj["llm_model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = (obj["llm_weight"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (m?.isEmpty == false ? m! : defaultModel, w?.isEmpty == false ? w! : defaultWeight)
    }

    private func fileOk(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).map { v in
            (v.isRegularFile ?? false) && ((v.fileSize ?? 0) > 0)
        } ?? false
    }

    private func downloadFile(
        from url: URL,
        to dest: URL,
        required: Bool,
        progress: @escaping (_ received: Int64, _ total: Int64?) -> Void
    ) async throws -> Bool {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // 对齐 Android：连接 30s，读取允许长时间（大文件下载）
        req.timeoutInterval = 30

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg)

        do {
            let (bytes, resp) = try await session.bytes(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 404, !required { return false }
            if let code = http?.statusCode, code != 200 {
                if required {
                    throw NSError(
                        domain: "AIIM",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: "模型下载失败（HTTP \(code)）：\(url.absoluteString)"]
                    )
                }
                return false
            }
            let total = http?.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }

            let handle = try FileHandle(forWritingTo: tmp, create: true)
            defer { try? handle.close() }

            var received: Int64 = 0
            var lastReport: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if received - lastReport >= 256 * 1024 || (total != nil && received >= total!) {
                    progress(received, total)
                    lastReport = received
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            progress(received, total)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return true
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if required {
                throw NSError(
                    domain: "AIIM",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: networkErrorHint(error, url: url)]
                )
            }
            return false
        }
    }

    private func networkErrorHint(_ error: Error, url: URL) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "无法连接模型服务器，请检查网络后重试。\n\(url.absoluteString)"
        case NSURLErrorTimedOut:
            return "下载超时，请稍后重试或检查网络。\n\(url.absoluteString)"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            return "无法建立连接，请检查域名/DNS或公网可达性。\n\(url.absoluteString)"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
            return "TLS/证书校验失败，请检查 HTTPS 证书链。\n\(url.absoluteString)"
        default:
            return (ns.localizedDescription.isEmpty ? "网络异常，请稍后重试。" : ns.localizedDescription) + "\n\(url.absoluteString)"
        }
    }
}

private extension FileHandle {
    convenience init(forWritingTo url: URL, create: Bool) throws {
        if create, !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try self.init(forWritingTo: url)
    }
}

