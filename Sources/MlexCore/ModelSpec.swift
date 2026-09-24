import Foundation

/// Which backend a session runs on. Parsed from strings like
/// `system`, `pcc`, `claude:sonnet5`, `mlx:mlx-community/Qwen3-8B-4bit`.
public enum ModelSpec: Sendable, Hashable, CustomStringConvertible {
    case system
    case pcc
    case claude(String)
    case mlx(String)
    /// Route every message to a tier (local / cheap / frontier) chosen by the router.
    case auto
    /// Any OpenAI-compatible provider configured in settings: `<provider>:<model>`.
    case provider(String, String)

    public static let `default`: ModelSpec = .system

    public init(parsing s: String) throws {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : nil) {
        case ("system", nil), ("apple", nil), ("local", nil): self = .system
        case ("auto", nil): self = .auto
        case ("pcc", nil), ("cloud", nil): self = .pcc
        case ("claude", let m): self = .claude(m ?? "sonnet5")
        case ("mlx", let id?): self = .mlx(id)
        case (let name, let model?) where Settings.load().allProviders[name] != nil && !model.isEmpty: self = .provider(name, model)
        default: throw MlexError.badModelSpec(s)
        }
    }

    public var description: String {
        switch self {
        case .system: "system"
        case .pcc: "pcc"
        case .claude(let m): "claude:\(m)"
        case .mlx(let id): "mlx:\(id)"
        case .auto: "auto"
        case .provider(let p, let m): "\(p):\(m)"
        }
    }
}

public enum MlexError: Error, CustomStringConvertible {
    case badModelSpec(String)
    case modelUnavailable(String)
    case missingAPIKey
    case notInstalled(String)
    case secretDetected(String)

    public var description: String {
        switch self {
        case .badModelSpec(let s): "unknown model spec '\(s)' (use auto | system | pcc | claude:<name> | mlx:<hf-id> | <provider>:<model>, providers: \(Settings.load().allProviders.keys.sorted().joined(separator: ", ")))"
        case .modelUnavailable(let why): "model unavailable: \(why)"
        case .missingAPIKey: "no Anthropic API key: set ANTHROPIC_API_KEY or add a Keychain item with service 'mlex-anthropic'"
        case .notInstalled(let id): "MLX model '\(id)' is not installed; run: mlex models pull \(id)"
        case .secretDetected(let what): "not sent: the message contains \(what). Nothing reached a model or the session. Refer to secrets by environment variable instead, for example \"Authorization: Bearer $API_TOKEN\"."
        }
    }
}
