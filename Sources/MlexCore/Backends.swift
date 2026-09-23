import Foundation
import FoundationModels
import ClaudeForFoundationModels

/// Turns a `ModelSpec` into something a `LanguageModelSession` can run on, plus availability info.
public enum Backends {
    public struct Status: Sendable { public var spec: String; public var available: Bool; public var detail: String }

    public static func status() async -> [Status] {
        var out: [Status] = []
        switch SystemLanguageModel.default.availability {
        case .available: out.append(.init(spec: "system", available: true, detail: "Apple on-device model"))
        case .unavailable(let r): out.append(.init(spec: "system", available: false, detail: "\(r)"))
        }
        let pcc = PrivateCloudComputeLanguageModel()
        switch pcc.availability {
        case .available: out.append(.init(spec: "pcc", available: Entitlements.hasPrivateCloudCompute,
                                          detail: Entitlements.hasPrivateCloudCompute ? "Private Cloud Compute"
                                                  : "needs the com.apple.developer.private-cloud-compute entitlement (signed app only)"))
        case .unavailable(let r): out.append(.init(spec: "pcc", available: false, detail: "\(r)"))
        }
        out.append(.init(spec: "claude:sonnet5", available: Secrets.anthropicKey() != nil,
                         detail: Secrets.anthropicKey() != nil ? "key found" : "no API key"))
        for m in await ModelStore.shared.installed() {
            out.append(.init(spec: "mlx:\(m.id)", available: true,
                             detail: ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)))
        }
        for m in await ModelStore.shared.partial() {
            out.append(.init(spec: "mlx:\(m.id)", available: false,
                             detail: "partial download (\(ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file))); pull again to resume"))
        }
        return out
    }

    /// Build a session for the spec. Kept as a factory because the session initializer is
    /// generic over the model type, so the branch has to happen at the call site.
    public static func makeSession(_ spec: ModelSpec, tools: [any Tool], instructions: String?,
                                   transcript: Transcript? = nil) async throws -> LanguageModelSession {
        switch spec {
        case .system:
            guard case .available = SystemLanguageModel.default.availability else {
                throw MlexError.modelUnavailable("Apple Intelligence is not enabled or the model is not ready")
            }
            if let t = transcript { return LanguageModelSession(model: .default, tools: tools, transcript: t) }
            return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        case .pcc:
            let m = PrivateCloudComputeLanguageModel()
            guard m.isAvailable else { throw MlexError.modelUnavailable("Private Cloud Compute: \(m.availability)") }
            guard Entitlements.hasPrivateCloudCompute else {
                throw MlexError.modelUnavailable("Private Cloud Compute requires the com.apple.developer.private-cloud-compute entitlement on a signed app; this executable does not have it")
            }
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        case .claude(let name):
            guard let key = Secrets.anthropicKey() else { throw MlexError.missingAPIKey }
            let model: ClaudeModel = switch name {
                case "sonnet5", "sonnet": .sonnet5
                case "opus", "opus5_5", "opus5.5": .opus5_5
                case "opus4_8", "opus4.8": .opus4_8
                default: ClaudeModel(id: name, capabilities: .init(effortLevels: [.low, .high], structuredOutput: true))
            }
            let m = ClaudeLanguageModel(name: model, auth: .apiKey(key))
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        case .mlx(let id):
            let m = try await ModelStore.shared.languageModel(for: id)
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        }
    }
}
