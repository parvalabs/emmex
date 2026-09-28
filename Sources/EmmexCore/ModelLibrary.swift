import Foundation

/// What a model's config.json says about it, and what its context window costs in memory.
public struct ModelInfo: Sendable {
    public var id: String
    public var path: String
    public var linked: Bool
    public var sizeBytes: Int64
    public var modelType: String
    public var layers: Int
    /// Layers that keep a per-token KV cache (hybrid models mix in linear-attention layers
    /// whose state does not grow with context).
    public var attentionLayers: Int
    public var quantBits: Int?
    public var maxContext: Int
    public var defaultContext: Int
    public var contextSetting: Int?
    /// fp16 K and V for every attention layer, per token.
    public var kvBytesPerToken: Int64

    public var context: Int { contextSetting.map { ModelInfo.clamp($0, max: maxContext) } ?? defaultContext }
    public func kvBytes(at tokens: Int) -> Int64 { kvBytesPerToken * Int64(tokens) }

    public static let minContext = 2048
    /// Default window: the model's own limit, capped so the KV cache stays modest on laptops.
    public static let defaultCap = 32_768
    static func clamp(_ n: Int, max: Int) -> Int { Swift.min(Swift.max(n, minContext), Swift.max(max, minContext)) }

    /// Parse an MLX model folder. Missing fields fall back to conservative values.
    public static func read(id: String, directory: URL, linked: Bool, sizeBytes: Int64, contextSetting: Int?) -> ModelInfo {
        let obj = (try? Data(contentsOf: directory.appending(path: "config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let text = obj["text_config"] as? [String: Any] ?? obj
        func int(_ k: String) -> Int? { (text[k] as? Int) ?? (obj[k] as? Int) }
        let layers = int("num_hidden_layers") ?? 0
        let heads = int("num_attention_heads") ?? 0
        let kvHeads = int("num_key_value_heads") ?? heads
        let headDim = int("head_dim") ?? (heads > 0 ? (int("hidden_size") ?? 0) / heads : 0)
        var attention = layers
        if let types = text["layer_types"] as? [String] { attention = types.filter { $0.contains("full") || $0 == "attention" }.count }
        else if let every = int("full_attention_interval"), every > 0 { attention = layers / every }
        let quant = (obj["quantization"] as? [String: Any])?["bits"] as? Int ?? (obj["quantization_config"] as? [String: Any])?["bits"] as? Int
        let maxContext = int("max_position_embeddings") ?? 8192
        return ModelInfo(id: id, path: directory.path, linked: linked, sizeBytes: sizeBytes,
                         modelType: (text["model_type"] as? String) ?? (obj["model_type"] as? String) ?? "unknown",
                         layers: layers, attentionLayers: attention, quantBits: quant, maxContext: maxContext,
                         defaultContext: min(maxContext, defaultCap), contextSetting: contextSetting,
                         kvBytesPerToken: Int64(2 * attention * kvHeads * headDim * 2))
    }
}

public enum ModelFolderError: Error, CustomStringConvertible {
    case notAModel(String)
    public var description: String { switch self { case .notAModel(let why): "not an MLX model folder: \(why)" } }
}

extension ModelStore {
    public func info(for id: String) -> ModelInfo {
        ModelInfo.read(id: id, directory: directory(for: id), linked: isLinked(id), sizeBytes: Self.size(of: directory(for: id)),
                       contextSetting: Settings.load().models[id]?.context)
    }

    /// Context window used for compaction and the context ring: the per-model setting, clamped
    /// to what the model supports, or the default.
    public func contextLength(for id: String) -> Int { info(for: id).context }

    /// Checks that a folder holds an MLX model in Hugging Face layout.
    public nonisolated static func validateFolder(_ url: URL) throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        guard files.contains("config.json") else { throw ModelFolderError.notAModel("no config.json") }
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) else { throw ModelFolderError.notAModel("no .safetensors weights") }
        guard files.contains(where: { ["tokenizer.json", "tokenizer.model", "tokenizer_config.json"].contains($0) }) else { throw ModelFolderError.notAModel("no tokenizer files") }
    }

    /// A free `local/<name>` id.
    func freeLocalID(_ name: String) -> String {
        let base = name.replacingOccurrences(of: "/", with: "-")
        var id = "local/\(base)", n = 2
        while linked[id] != nil || FileManager.default.fileExists(atPath: root.appending(path: id).path) { id = "local/\(base)-\(n)"; n += 1 }
        return id
    }

    /// Use a folder in place: the model is registered, its files stay where they are.
    public func link(_ url: URL) throws -> String {
        try Self.validateFolder(url)
        if let existing = linked.first(where: { $0.value == url.standardizedFileURL.path })?.key { return existing }
        let id = freeLocalID(url.lastPathComponent)
        linked[id] = url.standardizedFileURL.path
        try saveLinked()
        return id
    }

    /// Reserve an id for a copy into the library; the copy itself runs off the actor.
    public func reserveCopy(of url: URL) throws -> (id: String, destination: URL) {
        try Self.validateFolder(url)
        let id = freeLocalID(url.lastPathComponent)
        let dest = root.appending(path: id)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return (id, dest)
    }

    /// Copy a model folder file by file, reporting progress by bytes, then mark it complete.
    public nonisolated static func copyFolder(_ src: URL, to dest: URL, progress: @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: src.path).filter { !$0.hasPrefix(".") }
        let sizes = names.map { Int64((try? fm.attributesOfItem(atPath: src.appending(path: $0).path)[.size] as? Int) ?? 0) }
        let total = max(1, sizes.reduce(0, +)); var done: Int64 = 0
        for (name, size) in zip(names, sizes) {
            try Task.checkCancellation()
            let target = dest.appending(path: name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: src.appending(path: name), to: target)
            done += size; progress(Double(done) / Double(total))
        }
        fm.createFile(atPath: dest.appending(path: marker).path, contents: Data())
    }

    func unregister(_ id: String) { linked[id] = nil; try? saveLinked() }

    func saveLinked() throws {
        try FileManager.default.createDirectory(at: linkedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(linked).write(to: linkedFile, options: .atomic)
    }
}
