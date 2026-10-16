import Foundation
import Testing
@testable import EmmexCore

@Suite struct PromptCacheFilesTests {
    /// A fake model folder: a config and an empty weights file, never a real model.
    func fakeModel() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "emmex-pcf-\(UUID().uuidString)/org/Model-4bit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(to: dir.appending(path: "config.json"))
        FileManager.default.createFile(atPath: dir.appending(path: "model.safetensors").path, contents: Data())
        return dir
    }

    @Test func signatureChangesWithTheWeights() throws {
        let dir = try fakeModel(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        let before = PromptCacheFiles.signature(of: dir)
        #expect(before == PromptCacheFiles.signature(of: dir))
        try Data(count: 16).write(to: dir.appending(path: "model.safetensors"))
        #expect(before != PromptCacheFiles.signature(of: dir))
        #expect(PromptCacheFiles.prefix(for: dir) == "org--Model-4bit-")
    }

    @Test func removeDeletesOnlyThatModelsCaches() throws {
        let dir = try fakeModel(), fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "emmex-pcr-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        for name in ["org--Model-4bit-aaaaaaaaaaaa", "org--Model-4bit-bbbbbbbbbbbb", "org--Model-4bit-8bit-cccccccccccc", "other--Model-dddddddddddd"] {
            try fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        PromptCacheFiles.remove(modelDirectory: dir, root: root)
        #expect(try fm.contentsOfDirectory(atPath: root.path).sorted() == ["org--Model-4bit-8bit-cccccccccccc", "other--Model-dddddddddddd"])
    }
}
