import Foundation
import FoundationModels
import HuggingFace
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

    public init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/mlex/models")
    }

    public struct Installed: Sendable, Identifiable {
        public var id: String
        public var directory: URL
        public var sizeBytes: Int64
    }

    public func directory(for id: String) -> URL { root.appending(path: id) }

    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appending(path: "config.json").path)
    }

    /// Every `<org>/<name>` directory under root that has a config.json.
    public func installed() -> [Installed] {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [Installed] = []
        for org in orgs where !org.hasPrefix(".") {
            let orgURL = root.appending(path: org)
            guard let names = try? fm.contentsOfDirectory(atPath: orgURL.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let dir = orgURL.appending(path: name)
                guard fm.fileExists(atPath: dir.appending(path: "config.json").path) else { continue }
                out.append(.init(id: "\(org)/\(name)", directory: dir, sizeBytes: Self.size(of: dir)))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Download a repo snapshot from Hugging Face into the store. Safetensors, json, txt, jinja only.
    public func pull(_ id: String, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw MlexError.badModelSpec("mlx:\(id)") }
        let dest = directory(for: id)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let client = HubClient()
        _ = try await client.downloadSnapshot(
            of: repo, kind: .model, to: dest, revision: "main",
            matching: ["*.safetensors", "*.json", "*.txt", "*.jinja", "*.model"],
            progressHandler: { p in
                progress(p.fractionCompleted, p.localizedAdditionalDescription ?? "")
            })
        return dest
    }

    public func remove(_ id: String) throws {
        try FileManager.default.removeItem(at: directory(for: id))
        loaded[id] = nil
    }

    /// A `LanguageModel` for an installed MLX model. Instances are cached; the weights are
    /// loaded lazily by the framework on first use and kept warm by MLXLanguageModel's cache.
    public func languageModel(for id: String, reasoning: Bool = true) throws -> MLXLanguageModel {
        guard isInstalled(id) else { throw MlexError.notInstalled(id) }
        let key = "\(id)#\(reasoning)"
        if let m = loaded[key] { return m }
        let dir = directory(for: id)
        var caps: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
        if reasoning { caps.append(.reasoning) }
        let model = MLXLanguageModel(
            configuration: ModelConfiguration(directory: dir),
            capabilities: caps,
            weightsLocation: { _ in dir },
            load: { _, _ in try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader()) })
        loaded[key] = model
        return model
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
