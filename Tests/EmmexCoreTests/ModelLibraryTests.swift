import Foundation
import Testing
@testable import EmmexCore

@Suite struct ModelLibraryTests {
    func folder(_ config: [String: Any], files: [String] = ["model.safetensors", "tokenizer.json"]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "emmex-model-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appending(path: "config.json"))
        for f in files { FileManager.default.createFile(atPath: dir.appending(path: f).path, contents: Data("x".utf8)) }
        return dir
    }

    @Test func denseModelKVCost() throws {
        let dir = try folder(["model_type": "qwen3", "num_hidden_layers": 36, "num_attention_heads": 32, "num_key_value_heads": 8,
                              "head_dim": 128, "max_position_embeddings": 40960, "quantization": ["bits": 4]])
        let i = ModelInfo.read(id: "t/dense", directory: dir, linked: false, sizeBytes: 0, contextSetting: nil)
        #expect(i.kvBytesPerToken == 2 * 36 * 8 * 128 * 2)          // 144 KB per token
        #expect(i.defaultContext == 32_768 && i.context == 32_768)
        #expect(i.quantBits == 4 && i.attentionLayers == 36)
    }
    @Test func hybridModelCountsOnlyAttentionLayers() throws {
        let dir = try folder(["text_config": ["model_type": "qwen3_5_text", "num_hidden_layers": 32, "num_attention_heads": 16,
                                              "num_key_value_heads": 4, "head_dim": 256, "max_position_embeddings": 262144,
                                              "layer_types": Array(repeating: ["linear_attention", "linear_attention", "linear_attention", "full_attention"], count: 8).flatMap { $0 }]])
        let i = ModelInfo.read(id: "t/hybrid", directory: dir, linked: false, sizeBytes: 0, contextSetting: nil)
        #expect(i.attentionLayers == 8)
        #expect(i.kvBytesPerToken == 2 * 8 * 4 * 256 * 2)
        #expect(i.maxContext == 262_144)
    }
    @Test func contextSettingIsClampedToTheModel() throws {
        let dir = try folder(["num_hidden_layers": 2, "num_attention_heads": 2, "hidden_size": 64, "max_position_embeddings": 8192])
        #expect(ModelInfo.read(id: "t", directory: dir, linked: false, sizeBytes: 0, contextSetting: 100_000).context == 8192)
        #expect(ModelInfo.read(id: "t", directory: dir, linked: false, sizeBytes: 0, contextSetting: 10).context == ModelInfo.minContext)
        #expect(ModelInfo.read(id: "t", directory: dir, linked: false, sizeBytes: 0, contextSetting: nil).context == 8192)
    }
    @Test func folderValidation() throws {
        #expect(throws: (any Error).self) { try ModelStore.validateFolder(try folder([:], files: ["tokenizer.json"])) }
        #expect(throws: (any Error).self) { try ModelStore.validateFolder(try folder([:], files: ["model.safetensors"])) }
        try ModelStore.validateFolder(try folder([:]))
    }
    @Test func linkedModelsAreNeverDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "emmex-lib-\(UUID().uuidString.prefix(8))")
        let store = ModelStore(root: root)
        let src = try folder(["max_position_embeddings": 4096])
        let id = try await store.link(src)
        #expect(id.hasPrefix("local/"))
        #expect(await store.isInstalled(id))
        #expect(await store.installed().contains { $0.id == id && $0.linked })
        #expect(try await store.link(src) == id)                      // same folder, same id
        try await store.remove(id)
        #expect(!(await store.installed().contains { $0.id == id }))
        #expect(FileManager.default.fileExists(atPath: src.appending(path: "config.json").path))
    }
}
