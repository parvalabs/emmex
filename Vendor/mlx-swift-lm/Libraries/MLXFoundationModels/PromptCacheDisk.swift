// emmex patch: a disk tier for prompt caches, so a session's prefix survives a model unload or
// an app restart. See EMMEX-PATCHES.md at the package root.

#if FoundationModelsIntegration
#if canImport(FoundationModels, _version: 2)

import CryptoKit
import Foundation
import MLX
import MLXLMCommon

/// KV caches stored as 256-token blocks, one safetensors file each, named by a hash chained over
/// every token up to the block's end. A turn writes only its new blocks; a prompt loads the
/// longest run of stored blocks it begins with. Only plain attention caches (`KVCacheSimple` on
/// every layer) are stored: recurrent and rotating state cannot be cut into blocks.
enum PromptCacheDisk {
    static let blockSize = 256

    /// Folder for one model's blocks, or nil to keep that model off disk. Set by the host.
    nonisolated(unsafe) static var directory: (@Sendable (String) -> URL?)?
    /// Bytes all models' blocks may use; least recently used files go first. Set by the host.
    nonisolated(unsafe) static var maxBytes: Int64 = 10 << 30

    private static let pruneLock = NSLock()
    nonisolated(unsafe) private static var writtenSincePrune: Int64 = .max   // prune after the first write
    nonisolated(unsafe) private static var pruning = false

    static func supports(_ cache: [KVCache]) -> Bool {
        !cache.isEmpty && cache.allSatisfy { type(of: $0) == KVCacheSimple.self }
    }

    /// Chained hashes of the first `blocks` whole blocks of `tokens`.
    static func blockHashes(_ tokens: [Int], blocks: Int) -> [String] {
        var parent = Data("emmex-prompt-cache-v1".utf8)
        var hashes: [String] = []
        for b in 0 ..< min(blocks, tokens.count / blockSize) {
            var hasher = SHA256()
            hasher.update(data: parent)
            tokens[(b * blockSize) ..< ((b + 1) * blockSize)].map { Int32(truncatingIfNeeded: $0) }.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            let digest = Data(hasher.finalize())
            hashes.append(digest.map { String(format: "%02x", $0) }.joined())
            parent = digest
        }
        return hashes
    }

    static func file(_ dir: URL, _ hash: String) -> URL {
        dir.appending(path: String(hash.prefix(2))).appending(path: hash + ".safetensors")
    }

    /// Write the whole blocks of `entry` that are not on disk yet.
    static func save(_ entry: PromptCacheEntry, modelID: String) {
        guard let dir = directory?(modelID), supports(entry.cache), entry.isConsistent else { return }
        let blocks = entry.tokens.count / blockSize
        guard blocks > entry.savedBlocks else { return }
        let hashes = blockHashes(entry.tokens, blocks: blocks)
        let fm = FileManager.default
        var written: Int64 = 0
        for b in entry.savedBlocks ..< blocks {
            let url = file(dir, hashes[b])
            if fm.fileExists(atPath: url.path) { continue }
            var arrays: [String: MLXArray] = [:]
            for (i, layer) in entry.cache.enumerated() {
                let s = layer.state
                guard s.count == 2 else { return }
                let range = (b * blockSize) ..< ((b + 1) * blockSize)
                arrays["k\(i)"] = s[0][.ellipsis, range, 0...]
                arrays["v\(i)"] = s[1][.ellipsis, range, 0...]
            }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = url.deletingPathExtension().appendingPathExtension("tmp.safetensors")
                try MLX.save(arrays: arrays, metadata: ["layers": "\(entry.cache.count)"], url: tmp)
                try fm.moveItem(at: tmp, to: url)
                written += arrays.values.reduce(0) { $0 + Int64($1.nbytes) }
            } catch {
                return
            }
        }
        entry.savedBlocks = blocks
        notePruneNeeded(written: written, root: dir.deletingLastPathComponent())
    }

    /// How many whole blocks at the start of `tokens` (up to `limit` tokens) are on disk.
    static func storedBlocks(_ tokens: [Int], limit: Int, modelID: String) -> (dir: URL, hashes: [String])? {
        guard let dir = directory?(modelID) else { return nil }
        let fm = FileManager.default
        let hashes = blockHashes(tokens, blocks: limit / blockSize)
        let stored = hashes.prefix { fm.fileExists(atPath: file(dir, $0).path) }
        return stored.isEmpty ? nil : (dir, Array(stored))
    }

    /// Fill a fresh cache with the stored blocks. Returns false (cache untouched) on any mismatch.
    static func load(_ hashes: [String], dir: URL, into cache: [KVCache]) -> Bool {
        guard supports(cache) else { return false }
        var keys = Array(repeating: [MLXArray](), count: cache.count)
        var values = keys
        let now = Date()
        for h in hashes {
            let url = file(dir, h)
            guard let arrays = try? loadArrays(url: url) else { return false }
            for i in cache.indices {
                guard let k = arrays["k\(i)"], let v = arrays["v\(i)"], k.dim(2) == blockSize else { return false }
                keys[i].append(k); values[i].append(v)
            }
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        }
        for i in cache.indices {
            var layer = cache[i]
            layer.state = [concatenated(keys[i], axis: 2), concatenated(values[i], axis: 2)]
        }
        eval(cache.flatMap { $0.state })
        return true
    }

    private static func notePruneNeeded(written: Int64, root: URL) {
        pruneLock.lock()
        writtenSincePrune = writtenSincePrune == .max ? .max : writtenSincePrune + written
        let due = !pruning && writtenSincePrune >= 512 << 20
        if due { pruning = true; writtenSincePrune = 0 }
        pruneLock.unlock()
        guard due else { return }
        let limit = maxBytes
        Task.detached(priority: .utility) {
            prune(root: root, maxBytes: limit)
            pruneLock.withLock { pruning = false }
        }
    }

    /// Delete the least recently used block files under `root` until it fits in `maxBytes`.
    static func prune(root: URL, maxBytes: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in e where url.pathExtension == "safetensors" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { total -= f.size }
        }
    }
}

@available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
extension MLXLanguageModel {
    /// emmex patch: the folder for a model's prompt-cache blocks on disk (keyed by `modelID`), or
    /// nil to keep it in memory only. Unset means no disk tier.
    public static var promptCacheDirectory: (@Sendable (String) -> URL?)? {
        get { PromptCacheDisk.directory }
        set { PromptCacheDisk.directory = newValue }
    }

    /// emmex patch: bytes the disk tier may use across models (default 10 GB).
    public static var promptCacheDiskLimit: Int64 {
        get { PromptCacheDisk.maxBytes }
        set { PromptCacheDisk.maxBytes = newValue }
    }
}

#endif
#endif
