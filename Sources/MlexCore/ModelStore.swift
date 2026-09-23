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
