import Foundation
import FoundationModels
import ClaudeForFoundationModels
import FoundationModelsUtilities

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
        out.append(.init(spec: "claude:haiku", available: Secrets.anthropicKey() != nil,
                         detail: Secrets.anthropicKey() != nil ? "Haiku 4.5, the cheap tier" : "no API key"))
        let settings = Settings.load()
        for (name, p) in settings.allProviders.sorted(by: { $0.key < $1.key }) {
            let key = Secrets.providerKey(p)
            let ok = p.requiresKey == false || key != nil
            let models = (p.models ?? []).isEmpty ? ["<model>"] : p.models!
            for m in models {
                out.append(.init(spec: "\(name):\(m)", available: ok,
                                 detail: ok ? "\(p.url)" : "no key: set \(p.env ?? "-") or Keychain service \(p.keychain ?? "-")"))
            }
        }
        let r = settings.routes
        out.insert(.init(spec: "auto", available: true,
                         detail: "routes each message: local \(r.local) · cheap \(r.cheap) · frontier \(r.frontier)"), at: 0)
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
                                   transcript: Transcript? = nil,
                                   onWarning: (@Sendable (String) -> Void)? = nil) async throws -> LanguageModelSession {
        switch spec {
        case .system:
            guard case .available = SystemLanguageModel.default.availability else {
                throw EmlexError.modelUnavailable("Apple Intelligence is not enabled or the model is not ready")
            }
            if let t = transcript { return LanguageModelSession(model: .default, tools: tools, transcript: t) }
            return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        case .pcc:
            let m = PrivateCloudComputeLanguageModel()
            guard m.isAvailable else { throw EmlexError.modelUnavailable("Private Cloud Compute: \(m.availability)") }
            guard Entitlements.hasPrivateCloudCompute else {
                throw EmlexError.modelUnavailable("Private Cloud Compute requires the com.apple.developer.private-cloud-compute entitlement on a signed app; this executable does not have it")
            }
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        case .claude(let name):
            guard let key = Secrets.anthropicKey() else { throw EmlexError.missingAPIKey }
            let model: ClaudeModel = switch name {
                case "sonnet5", "sonnet": .sonnet5
                case "opus", "opus5_5", "opus5.5": .opus5_5
                case "opus4_8", "opus4.8": .opus4_8
                case "haiku", "haiku4_5", "haiku4.5": ClaudeModel(id: "claude-haiku-4-5-20251001", capabilities: .init(effortLevels: [], structuredOutput: true))
                default: ClaudeModel(id: name, capabilities: .init(effortLevels: [.low, .high], structuredOutput: true))
            }
            let m = ClaudeLanguageModel(name: model, auth: .apiKey(key))
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        case .auto:
            // Sessions on auto start on the local tier; AgentSession re-routes per message.
            let resolver = await TierResolver.current()
            return try await makeSession(resolver.spec(for: .local), tools: tools, instructions: instructions, transcript: transcript, onWarning: onWarning)
        case .provider(let name, let modelID):
            guard let p = Settings.load().allProviders[name] else { throw EmlexError.badModelSpec("\(name):\(modelID)") }
            guard let url = URL(string: p.url) else { throw EmlexError.badModelSpec("provider \(name) url \(p.url)") }
            var headers = p.headers ?? [:]
            if let key = Secrets.providerKey(p) { headers["Authorization"] = "Bearer \(key)" }
            else if p.requiresKey != false { throw EmlexError.modelUnavailable("no API key for \(name): set \(p.env ?? "an env var") or Keychain service \(p.keychain ?? "-")") }
            let m = ChatCompletionsLanguageModel(name: modelID, url: url, additionalHeaders: headers, supportsGuidedGeneration: p.guided ?? true)
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        case .mlx(let id):
            let (needed, available) = await ModelStore.shared.headroom(for: id)
            if needed > 0, needed > available {
                onWarning?("\(id) needs about \(SystemMemory.format(needed)) but only \(SystemMemory.format(available)) is available; expect swapping")
            }
            let m = try await ModelStore.shared.languageModel(for: id)
            if let t = transcript { return LanguageModelSession(model: m, tools: tools, transcript: t) }
            return LanguageModelSession(model: m, tools: tools, instructions: instructions)
        }
    }
}
