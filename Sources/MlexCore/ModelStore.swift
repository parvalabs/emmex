import Foundation
import FoundationModels
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers

/// Local MLX model library: `~/.cache/mlex/models/<org>/<name>` in plain Hugging Face layout.
public actor ModelStore {
    public static let shared = ModelStore()

    public let root: URL
    private var loaded: [String: MLXLanguageModel] = [:]
    /// The one MLX model whose weights are resident. Selecting another evicts it.
    public private(set) var residentID: String?
    /// Sent when residency changes, so UIs can update without polling.
    public var onResidentChange: (@Sendable (String?) -> Void)?

    public init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/mlex/models")
    }

    public struct Installed: Sendable, Identifiable {
        public var id: String
        public var directory: URL
        public var sizeBytes: Int64
    }

    public func directory(for id: String) -> URL { root.appending(path: id) }

    static let marker = ".mlex-complete"

    /// Installed means the pull finished: a completion marker is written after the last file.
    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appending(path: Self.marker).path)
    }

    /// A directory exists for the model but the pull never completed.
    public func isPartial(_ id: String) -> Bool {
        let dir = directory(for: id)
        return !isInstalled(id) && FileManager.default.fileExists(atPath: dir.path)
    }

    /// Model directories whose pull was interrupted; pulling again resumes them.
    public func partial() -> [Installed] {
        scan().filter { !isInstalled($0.id) }
    }

    /// Every completed `<org>/<name>` model under root.
    public func installed() -> [Installed] {
        scan().filter { isInstalled($0.id) }
    }

    private func scan() -> [Installed] {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [Installed] = []
        for org in orgs where !org.hasPrefix(".") {
            let orgURL = root.appending(path: org)
            guard let names = try? fm.contentsOfDirectory(atPath: orgURL.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let dir = orgURL.appending(path: name)
                guard (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == false else { continue }
                out.append(.init(id: "\(org)/\(name)", directory: dir, sizeBytes: Self.size(of: dir)))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Download a model repo into the store with byte-level progress (fraction, "x of y MB · file").
    public func pull(_ id: String, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        guard id.split(separator: "/").count == 2 else { throw MlexError.badModelSpec("mlx:\(id)") }
        let dest = directory(for: id)
        try await HFDownloader.download(repo: id, into: dest) { done, total, file in
            let f = ByteCountFormatter(); f.countStyle = .file
            progress(total > 0 ? Double(done) / Double(total) : 0,
                     "\(f.string(fromByteCount: done)) of \(f.string(fromByteCount: total)) · \(file)")
        }
        FileManager.default.createFile(atPath: dest.appending(path: Self.marker).path, contents: Data())
        return dest
    }

    public func remove(_ id: String) async throws {
        if residentID == id { await unloadResident() }
        try FileManager.default.removeItem(at: directory(for: id))
        loaded[id] = nil
    }

    /// A `LanguageModel` for an installed MLX model, with its weights loaded. Only one MLX
    /// model is kept resident: asking for a different one evicts the previous model first.
    /// `.reasoning` is always declared so thinking can be switched per request via `Effort`.
    public func languageModel(for id: String) async throws -> MLXLanguageModel {
        guard isInstalled(id) else { throw MlexError.notInstalled(id) }
        if residentID != id { await unloadResident() }
        let model: MLXLanguageModel
        if let m = loaded[id] { model = m } else {
            let dir = directory(for: id)
            model = MLXLanguageModel(
                configuration: ModelConfiguration(directory: dir),
                capabilities: [.guidedGeneration, .toolCalling, .reasoning],
                weightsLocation: { _ in dir },
                load: { _, _ in try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader()) })
            loaded[id] = model
        }
        try await model.preload()
        residentID = id
        onResidentChange?(id)
        return model
    }

    /// Context length declared by the model's config.json, capped at 32k.
    public func contextLength(for id: String) -> Int {
        let url = directory(for: id).appending(path: "config.json")
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 8192 }
        let text = obj["text_config"] as? [String: Any] ?? obj
        let n = (text["max_position_embeddings"] as? Int) ?? (obj["max_position_embeddings"] as? Int) ?? 8192
        return min(n, 32_768)
    }

    /// Free the resident model's weights. The next use reloads from disk.
    public func unloadResident() async {
        guard let id = residentID else { return }
        await loaded[id]?.evict()
        residentID = nil
        onResidentChange?(nil)
    }

    /// How much memory loading `id` would need versus what the system can spare right now.
    /// Weights map at roughly their on-disk size; working memory adds a margin.
    public func headroom(for id: String) -> (needed: Int64, available: Int64) {
        let needed = Int64(Double(Self.size(of: directory(for: id))) * 1.15)
        return (needed, SystemMemory.available())
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
