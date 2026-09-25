import Foundation
import FoundationModels
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import Tokenizers

/// Local MLX model library: `~/.cache/emlex/models/<org>/<name>` in plain Hugging Face layout.
public actor ModelStore {
    public static let shared = ModelStore()

    public let root: URL
    private var loaded: [String: MLXLanguageModel] = [:]
    /// MLX models whose weights are resident, least recently used first. Loading another model
    /// evicts from the front until it fits.
    public private(set) var residents: [String] = []
    /// The most recently used resident model.
    public var residentID: String? { residents.last }
    /// Sent when residency changes, so UIs can update without polling.
    public var onResidentChange: (@Sendable ([String]) -> Void)?

    public struct Resident: Sendable, Identifiable {
        public var id: String
        public var sizeBytes: Int64
    }
    /// Resident models with their on-disk weight size (close to what they map in memory).
    public func residentModels() -> [Resident] {
        residents.reversed().map { Resident(id: $0, sizeBytes: Self.size(of: directory(for: $0))) }
    }

    /// Models used in place from a folder outside the library: id (`local/<name>`) → path.
    /// Their files belong to the user; removing one only unregisters it.
    var linked: [String: String] = [:]
    let linkedFile: URL

    public init(root: URL? = nil) {
        self.root = root ?? Paths.cacheRoot.appending(path: "models")
        self.linkedFile = (root == nil ? Paths.appSupport : self.root).appending(path: "linked-models.json")
        self.linked = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: linkedFile))) ?? [:]
    }

    public struct Installed: Sendable, Identifiable {
        public var id: String
        public var directory: URL
        public var sizeBytes: Int64
        public var linked: Bool = false
    }

    public func directory(for id: String) -> URL {
        if let path = linked[id] { return URL(fileURLWithPath: path) }
        return root.appending(path: id)
    }
    public func isLinked(_ id: String) -> Bool { linked[id] != nil }

    static let marker = ".emlex-complete"
    static let legacyMarker = ".mlex-complete"   // pulls finished before the rename

    /// Installed means the pull finished: a completion marker is written after the last file.
    public func isInstalled(_ id: String) -> Bool {
        let dir = directory(for: id)
        if linked[id] != nil { return FileManager.default.fileExists(atPath: dir.appending(path: "config.json").path) }
        return [Self.marker, Self.legacyMarker].contains { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
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
        let local = scan().filter { isInstalled($0.id) }
        let used = linked.keys.sorted().filter { isInstalled($0) }.map {
            Installed(id: $0, directory: directory(for: $0), sizeBytes: Self.size(of: directory(for: $0)), linked: true)
        }
        return (local + used).sorted { $0.id < $1.id }
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
        guard id.split(separator: "/").count == 2 else { throw EmlexError.badModelSpec("mlx:\(id)") }
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
        if residents.contains(id) { await unload(id) }
        if linked[id] != nil { unregister(id); loaded[id] = nil; return }   // never delete the user's folder
        let dir = directory(for: id), fm = FileManager.default
        try fm.removeItem(at: dir)
        loaded[id] = nil
        // Drop the organization folder too once its last model is gone.
        let org = dir.deletingLastPathComponent()
        if org.path != root.path, (try? fm.contentsOfDirectory(atPath: org.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true { try? fm.removeItem(at: org) }
    }

    /// A `LanguageModel` for an installed MLX model, with its weights loaded. Several models can
    /// stay resident; when memory is short the least recently used ones are evicted first.
    /// `.reasoning` is always declared so thinking can be switched per request via `Effort`.
    public func languageModel(for id: String) async throws -> MLXLanguageModel {
        guard isInstalled(id) else { throw EmlexError.notInstalled(id) }
        if residents.contains(id) {
            residents.removeAll { $0 == id }; residents.append(id)   // most recently used
        } else {
            let needed = Self.needed(for: directory(for: id))
            while !residents.isEmpty, needed > SystemMemory.available() { await unload(residents[0]) }
        }
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
        if !residents.contains(id) { residents.append(id) }
        onResidentChange?(residents)
        return model
    }

    /// Free one resident model's weights. The next use reloads from disk.
    public func unload(_ id: String) async {
        guard residents.contains(id) else { return }
        await loaded[id]?.evict()
        residents.removeAll { $0 == id }
        onResidentChange?(residents)
    }

    /// Free every resident model.
    public func unloadAll() async { for id in residents.reversed() { await unload(id) } }

    /// Kept for callers that only know about one resident: unloads the most recently used.
    public func unloadResident() async { if let id = residentID { await unload(id) } }

    /// How much memory loading `id` would need versus what the system can spare, counting the
    /// residents that would be evicted to make room. An already-resident model needs nothing.
    public func headroom(for id: String) -> (needed: Int64, available: Int64) {
        if residents.contains(id) { return (0, SystemMemory.available()) }
        let needed = Self.needed(for: directory(for: id))
        let reclaimable = residents.reduce(Int64(0)) { $0 + Self.needed(for: directory(for: $1)) }
        return (needed, SystemMemory.available() + reclaimable)
    }

    /// Weights map at roughly their on-disk size; working memory adds a margin.
    static func needed(for dir: URL) -> Int64 { Int64(Double(size(of: dir)) * 1.15) }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
