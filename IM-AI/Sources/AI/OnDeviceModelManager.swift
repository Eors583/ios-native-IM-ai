import Foundation

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

@MainActor
final class OnDeviceModelManager {
    private let defaults = UserDefaults.standard
    private let selectedKey = "aiim_ondevice_llm.selected_model_id"

    // 与 Android 保持一致
    private let ossModelBase = URL(string: "https://oss-mnn.obs.cn-south-1.myhuaweicloud.com/mnn")!
    private let defaultModelId = "qwen3.5"

    func availableModels() -> [OnDeviceModelOption] {
        [
            .init(id: "qwen3.5", displayName: "Qwen 3.5"),
        ]
    }

    func selectedModelId() -> String {
        (defaults.string(forKey: selectedKey) ?? defaultModelId).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isActiveModelReady() -> Bool {
        isModelReady(modelId: selectedModelId())
    }

    func isModelReady(modelId: String) -> Bool {
        let dir = modelStorageDir(modelId: modelId)
        let config = dir.appendingPathComponent("config.json")
        guard fileOk(config) else { return false }

        let names = runtimeModelFileNames(modelDir: dir)
        let llm = dir.appendingPathComponent(names.llmModel)
        let w = dir.appendingPathComponent(names.llmWeight)
        let tok = dir.appendingPathComponent("tokenizer.txt")
        return fileOk(llm) && fileOk(w) && fileOk(tok)
    }

    func downloadAndActivateModel(
        modelId: String,
        forceRedownload: Bool,
        onProgress: @escaping (ModelDownloadProgress) -> Void
    ) async -> Result<Void, Error> {
        do {
            try await syncModelFromOss(modelId: modelId, forceRedownload: forceRedownload, onProgress: onProgress)
            defaults.set(modelId, forKey: selectedKey)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Private

    private func modelStorageDir(modelId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("mnn/\(modelId)", isDirectory: true)
    }

    private func ossBaseUrl(modelId: String) -> URL {
        ossModelBase.appendingPathComponent(modelId, conformingTo: .folder)
    }

    private func syncModelFromOss(
        modelId: String,
        forceRedownload: Bool,
        onProgress: @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        let modelDir = modelStorageDir(modelId: modelId)
        if forceRedownload {
            try? FileManager.default.removeItem(at: modelDir)
        }
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

        // 1) config.json
        let configDest = modelDir.appendingPathComponent("config.json")
        if !forceRedownload, fileOk(configDest) {
            report("config.json", 1, 0, nil, true)
        } else {
            try await downloadFile(
                from: base.appendingPathComponent("config.json"),
                to: configDest,
                required: true,
                progress: { r, t in report("config.json", 1, r, t, false) }
            )
        }

        let names = runtimeModelFileNames(modelDir: modelDir)

        // 2) llm model
        let llmDest = modelDir.appendingPathComponent(names.llmModel)
        if !forceRedownload, fileOk(llmDest) {
            report(names.llmModel, 2, 0, nil, true)
        } else {
            try await downloadFile(
                from: base.appendingPathComponent(names.llmModel),
                to: llmDest,
                required: true,
                progress: { r, t in report(names.llmModel, 2, r, t, false) }
            )
        }

        // 3) llm weight
        let weightDest = modelDir.appendingPathComponent(names.llmWeight)
        if !forceRedownload, fileOk(weightDest) {
            report(names.llmWeight, 3, 0, nil, true)
        } else {
            try await downloadFile(
                from: base.appendingPathComponent(names.llmWeight),
                to: weightDest,
                required: true,
                progress: { r, t in report(names.llmWeight, 3, r, t, false) }
            )
        }

        // 4) tokenizer.txt
        let tokDest = modelDir.appendingPathComponent("tokenizer.txt")
        if !forceRedownload, fileOk(tokDest) {
            report("tokenizer.txt", 4, 0, nil, true)
        } else {
            try await downloadFile(
                from: base.appendingPathComponent("tokenizer.txt"),
                to: tokDest,
                required: true,
                progress: { r, t in report("tokenizer.txt", 4, r, t, false) }
            )
        }

        // optional files
        for (i, name) in optionalFiles.enumerated() {
            let stepIndex = 5 + i
            let dest = modelDir.appendingPathComponent(name)
            if !forceRedownload, fileOk(dest) {
                report(name, stepIndex, 0, nil, true)
                continue
            }
            do {
                let ok = try await downloadFile(
                    from: base.appendingPathComponent(name),
                    to: dest,
                    required: false,
                    progress: { r, t in report(name, stepIndex, r, t, false) }
                )
                if !ok {
                    report(name, stepIndex, 0, nil, true)
                }
            } catch {
                // optional: ignore
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

    /// - Returns: `false` if optional file 404.
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
        req.timeoutInterval = 30

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 404, !required {
            return false
        }
        if let code = http?.statusCode, code != 200 {
            if required { throw NSError(domain: "AIIM", code: code, userInfo: [NSLocalizedDescriptionKey: "模型下载失败（HTTP \(code)）"]) }
            return false
        }
        let total = http?.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }

        let handle = try FileHandle(forWritingTo: tmp, create: true)
        defer { try? handle.close() }

        var received: Int64 = 0
        var lastReport: Int64 = 0
        for try await chunk in bytes {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)
            if received - lastReport >= 256 * 1024 || (total != nil && received >= total!) {
                progress(received, total)
                lastReport = received
            }
        }
        progress(received, total)

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return true
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

