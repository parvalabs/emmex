import CryptoKit
import Foundation
import MLXFoundationModels

/// Where MLX prompt caches go on disk: `~/.cache/emmex/prompt-cache/<org>--<name>-<signature>`.
/// The signature covers `config.json` and the weight files' names, sizes and dates, so replaced
/// weights never load a stale cache. `EMMEX_MLX_DISK_CACHE=0` keeps caches in memory only;
/// `EMMEX_MLX_DISK_CACHE_GB` sets the size limit (default 10); `EMMEX_MLX_DISK_CACHE_DIR` moves it.
public enum PromptCacheFiles {
    public static var root: URL {
        Env.value("EMMEX_MLX_DISK_CACHE_DIR").map { URL(fileURLWithPath: $0) } ?? Paths.cacheRoot.appending(path: "prompt-cache")
    }
    static var enabled: Bool { Env.value("EMMEX_MLX_DISK_CACHE") != "0" }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var folders: [String: URL] = [:]   // MLX model name → folder

    /// Point the MLX adapter at this store. Safe to call more than once.
    public static func install() {
        guard enabled else { return }
        MLXLanguageModel.promptCacheDirectory = { name in lock.withLock { folders[name] } }
        if let gb = Env.value("EMMEX_MLX_DISK_CACHE_GB").flatMap(Double.init) { MLXLanguageModel.promptCacheDiskLimit = Int64(gb * Double(1 << 30)) }
    }

    /// Register a model folder before its first turn. `name` is the adapter's model name.
    public static func register(name: String, modelDirectory dir: URL) {
        guard enabled else { return }
        let folder = root.appending(path: prefix(for: dir) + signature(of: dir))
        lock.withLock { folders[name] = folder }
    }

    /// Delete every cache for a model folder, current signature or not.
    public static func remove(modelDirectory dir: URL, root: URL = root) {
        let p = prefix(for: dir), fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        where item.hasPrefix(p) && item.dropFirst(p.count).count == 12 && item.dropFirst(p.count).allSatisfy(\.isHexDigit) {
            try? fm.removeItem(at: root.appending(path: item))
        }
    }

    static func prefix(for dir: URL) -> String {
        "\(dir.deletingLastPathComponent().lastPathComponent)--\(dir.lastPathComponent)-"
    }

    static func signature(of dir: URL) -> String {
        var h = SHA256()
        if let config = try? Data(contentsOf: dir.appending(path: "config.json")) { h.update(data: config) }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "safetensors" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            h.update(data: Data("\(f.lastPathComponent):\(v?.fileSize ?? 0):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)\n".utf8))
        }
        return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
