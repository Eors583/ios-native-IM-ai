import Foundation

/// 端侧 MNN LLM：封装官方 `LLMInferenceEngineWrapper`，行为对齐 Android `MnnOnDeviceQaEngine`（人设提示词 + 流式输出）。
final class MnnOnDeviceLlmEngine {
    enum MnnLlmError: Error {
        case loadFailed
        case engineMissing
    }

    private var wrapper: LLMInferenceEngineWrapper?
    private let modelDir: URL

    init(modelDirectory: URL) {
        modelDir = modelDirectory
    }

    /// 异步加载模型（在全局队列执行；完成回调在主线程）。
    func load() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var instance: LLMInferenceEngineWrapper?
            instance = LLMInferenceEngineWrapper(modelPath: modelDir.path) { success in
                guard let inst = instance else {
                    cont.resume(throwing: MnnLlmError.loadFailed)
                    return
                }
                if success {
                    self.wrapper = inst
                    self.applyMergedConfigs()
                    cont.resume()
                } else {
                    cont.resume(throwing: MnnLlmError.loadFailed)
                }
            }
            _ = instance
        }
    }

    func cancelGeneration() {
        wrapper?.cancelInference()
    }

    /// 流式生成；结束标记 `<eop>` / `<stoped>` 由封装层传入，此处过滤，不交给 UI。
    func streamAnswer(prompt: String, onToken: @escaping (String) -> Void) async {
        guard let w = wrapper else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            w.clearChatHistory()
            w.processInput(prompt) { token in
                if token == "<eop>" || token == "<stoped>" {
                    cont.resume()
                    return
                }
                onToken(token)
            }
        }
    }

    private func applyMergedConfigs() {
        guard let w = wrapper else { return }
        let merged = Self.loadMergedConfigJson(modelDir: modelDir)
        if merged != "{}" {
            w.setConfigWithJSONString(merged)
        }
        w.setConfigWithJSONString(Self.runtimeConfigJson())
    }

    /// 与 `MnnOnDeviceQaEngine.loadMergedConfigJson` 对齐：优先 `llm_config.json`，否则 `configuration.json`。
    private static func loadMergedConfigJson(modelDir: URL) -> String {
        let primary = modelDir.appendingPathComponent("llm_config.json")
        let fallback = modelDir.appendingPathComponent("configuration.json")
        let url: URL
        if FileManager.default.fileExists(atPath: primary.path) {
            url = primary
        } else if FileManager.default.fileExists(atPath: fallback.path) {
            url = fallback
        } else {
            return "{}"
        }
        guard let data = try? Data(contentsOf: url),
              var obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return "{}"
        }
        let stringKeys = [
            "model_type", "attention_mask", "attention_type", "tokenizer",
            "llm_model", "llm_weight"
        ]
        for key in stringKeys {
            if obj[key] is NSNull {
                obj[key] = ""
            }
        }
        if var jinja = obj["jinja"] as? [String: Any] {
            if jinja["eos"] is NSNull { jinja["eos"] = "" }
            if jinja["chat_template"] is NSNull { jinja["chat_template"] = "" }
            obj["jinja"] = jinja
        }
        obj["is_visual"] = false
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: out, encoding: .utf8)
        else {
            return "{}"
        }
        return s
    }

    private static func runtimeConfigJson() -> String {
        "{\"is_r1\":false,\"mmap_dir\":\"\",\"keep_history\":false}"
    }
}
