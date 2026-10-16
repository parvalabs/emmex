// emmex patch: tests for the prompt-cache disk tier.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import MLXFoundationModels

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)

@Suite(.serialized) struct PromptCacheDiskTests {
    let bs = PromptCacheDisk.blockSize

    func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "emmex-pc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two layers whose keys encode the token position, so a reload can be checked exactly.
    func entry(tokens: [Int]) -> PromptCacheEntry {
        let cache: [KVCache] = (0 ..< 2).map { layer in
            let c = KVCacheSimple()
            let pos = MLXArray((0 ..< tokens.count).map { Float($0 + layer * 10_000) }).reshaped([1, 1, tokens.count, 1])
            _ = c.update(keys: MLXArray.ones([1, 1, 1, 4]) * pos, values: MLXArray.ones([1, 1, 1, 4]) * (pos + 0.5))
            return c
        }
        return PromptCacheEntry(cache: cache, tokens: tokens)
    }

    @Test func hashesChainOverThePrefix() {
        let a = Array(0 ..< 3 * bs), b = Array(0 ..< 2 * bs) + Array(repeating: 7, count: bs)
        let ha = PromptCacheDisk.blockHashes(a, blocks: 3), hb = PromptCacheDisk.blockHashes(b, blocks: 3)
        #expect(ha.count == 3)
        #expect(ha[0] == hb[0] && ha[1] == hb[1] && ha[2] != hb[2])
        // The same block after a different prefix gets a different name.
        let shifted = PromptCacheDisk.blockHashes(Array(repeating: 1, count: bs) + Array(0 ..< bs), blocks: 2)
        #expect(shifted[1] != ha[0])
    }

    @Test func saveThenLoadRestoresTheCache() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        PromptCacheDisk.directory = { _ in dir }; defer { PromptCacheDisk.directory = nil }
        let tokens = Array(0 ..< (2 * bs + 10))
        let e = entry(tokens: tokens)
        PromptCacheDisk.save(e, modelID: "m")
        #expect(e.savedBlocks == 2)

        let stored = try #require(PromptCacheDisk.storedBlocks(tokens + [1, 2], limit: tokens.count + 1, modelID: "m"))
        #expect(stored.hashes.count == 2)
        let fresh: [KVCache] = [KVCacheSimple(), KVCacheSimple()]
        #expect(PromptCacheDisk.load(stored.hashes, dir: stored.dir, into: fresh))
        #expect(fresh.allSatisfy { $0.offset == 2 * bs })
        let original = e.cache[1].state[0][.ellipsis, ..<(2 * bs), 0...]
        #expect(allClose(fresh[1].state[0], original).item(Bool.self))
    }

    @Test func storedBlocksStopsAtTheFirstMissingBlock() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        PromptCacheDisk.directory = { _ in dir }; defer { PromptCacheDisk.directory = nil }
        let tokens = Array(0 ..< 3 * bs)
        PromptCacheDisk.save(entry(tokens: tokens), modelID: "m")
        let hashes = PromptCacheDisk.blockHashes(tokens, blocks: 3)
        try? FileManager.default.removeItem(at: PromptCacheDisk.file(dir, hashes[1]))
        #expect(PromptCacheDisk.storedBlocks(tokens, limit: tokens.count, modelID: "m")?.hashes == [hashes[0]])
        // The limit keeps the last prompt token out of the restored prefix.
        #expect(PromptCacheDisk.storedBlocks(Array(tokens.prefix(bs)), limit: bs - 1, modelID: "m") == nil)
    }

    @Test func untrimmableCachesStayOffDisk() {
        #expect(!PromptCacheDisk.supports([MambaCache()]))
        #expect(PromptCacheDisk.supports([KVCacheSimple()]))
    }

    @Test func pruneDeletesLeastRecentlyUsedFirst() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for (i, name) in ["old", "mid", "new"].enumerated() {
            let url = dir.appending(path: "m/\(name).safetensors")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(count: 100))
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 1000)], ofItemAtPath: url.path)
        }
        PromptCacheDisk.prune(root: dir, maxBytes: 200)
        let left = try fm.contentsOfDirectory(atPath: dir.appending(path: "m").path).sorted()
        #expect(left == ["mid.safetensors", "new.safetensors"])
    }
}

#endif
