import Foundation

/// User settings at ~/.emmex/settings.json. Only the router tiers exist so far.
public struct Settings: Codable, Sendable {
    public struct Routes: Codable, Sendable {
        public var local: String = "system"
        public var cheap: String = "claude:haiku"
        public var frontier: String = "claude:sonnet5"
        public init() {}
        enum CodingKeys: String, CodingKey { case local, cheap, frontier }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            local = try c.decodeIfPresent(String.self, forKey: .local) ?? "system"
            cheap = try c.decodeIfPresent(String.self, forKey: .cheap) ?? "claude:haiku"
            frontier = try c.decodeIfPresent(String.self, forKey: .frontier) ?? "claude:sonnet5"
        }
    }
    public var routes = Routes()
    public init() {}

    // Every key is optional in the file: a partial settings.json keeps the defaults for the rest.
    enum CodingKeys: String, CodingKey { case routes, router, memory, providers, permission, sandbox, network, unsandboxedRetry, secretScan, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        routes = try c.decodeIfPresent(Routes.self, forKey: .routes) ?? Routes()
        router = try c.decodeIfPresent(String.self, forKey: .router) ?? "ondevice"
        memory = try c.decodeIfPresent(Bool.self, forKey: .memory) ?? true
        providers = try c.decodeIfPresent([String: Provider].self, forKey: .providers)
        permission = try c.decodeIfPresent(String.self, forKey: .permission) ?? "smart"
        sandbox = try c.decodeIfPresent(Bool.self, forKey: .sandbox) ?? true
        network = try c.decodeIfPresent(Network.self, forKey: .network) ?? Network()
        unsandboxedRetry = try c.decodeIfPresent(Bool.self, forKey: .unsandboxedRetry) ?? true
        secretScan = try c.decodeIfPresent(Bool.self, forKey: .secretScan) ?? true
        models = try c.decodeIfPresent([String: ModelPrefs].self, forKey: .models) ?? [:]
    }
    /// "ondevice" (default) or "jev" (TypeSafe Jev; needs a key in Keychain service `emmex-jev` or JEV_API_KEY).
    public var router: String = "ondevice"
    /// Remember facts from conversations and inject relevant ones.
    public var memory: Bool = true
    /// Default permission level for new sessions: ask | smart | full.
    public var permission: String = "smart"
    /// Run shell commands under a Seatbelt sandbox (writes confined to the workspace and tool
    /// caches, credential directories unreadable, network only when the policy grants it).
    public var sandbox: Bool = true
    public struct Network: Codable, Sendable {
        /// Domains commands may reach in addition to the package-manager defaults ("*.example.com").
        public var allowedDomains: [String] = []
        public init() {}
        enum CodingKeys: String, CodingKey { case allowedDomains }
        public init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); allowedDomains = try c.decodeIfPresent([String].self, forKey: .allowedDomains) ?? [] }
    }
    public var network = Network()
    /// When a sandboxed command fails on a sandbox denial, offer to rerun it unsandboxed
    /// (asks, except in full mode where it retries with an audit line). false: never.
    public var unsandboxedRetry: Bool = true
    /// Block messages that contain passwords, tokens or keys before they reach any model.
    public var secretScan: Bool = true
    /// Per-model preferences, keyed by MLX model id.
    public struct ModelPrefs: Codable, Sendable {
        /// Context window in tokens; nil uses the model's default.
        public var context: Int?
        public init(context: Int? = nil) { self.context = context }
    }
    public var models: [String: ModelPrefs] = [:]

    /// OpenAI-compatible chat-completions providers, keyed by the name used in specs (`<name>:<model>`).
    public struct Provider: Codable, Sendable, Hashable {
        public var url: String                       // base URL, e.g. https://api.openai.com/v1
        public var keychain: String?                 // Keychain service holding the API key
        public var env: String?                      // env var holding the API key
        public var headers: [String: String]?        // extra headers
        public var models: [String]?                 // suggested model ids for the picker
        public var guided: Bool?                     // supports response_format json_schema (default true)
        public var context: Int?                     // context window in tokens (default 128k)
        public var requiresKey: Bool?                // false for local servers (default true)
        public init(url: String, keychain: String? = nil, env: String? = nil, headers: [String: String]? = nil, models: [String]? = nil, guided: Bool? = nil, context: Int? = nil, requiresKey: Bool? = nil) {
            self.url = url; self.keychain = keychain; self.env = env; self.headers = headers; self.models = models; self.guided = guided; self.context = context; self.requiresKey = requiresKey
        }
    }
    public var providers: [String: Provider]? = nil

    /// Built-in providers, overridable per name in settings.json.
    public static let defaultProviders: [String: Provider] = [
        "openai": Provider(url: "https://api.openai.com/v1", keychain: "emmex-openai", env: "OPENAI_API_KEY",
                           models: ["gpt-5", "gpt-5.5", "gpt-5-mini"], context: 400_000),
        "bedrock": Provider(url: "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1", keychain: "emmex-bedrock", env: "AWS_BEARER_TOKEN_BEDROCK",
                            models: ["openai.gpt-oss-120b-1:0", "openai.gpt-oss-20b-1:0"], context: 128_000),
        "ollama": Provider(url: "http://localhost:11434/v1", models: [], guided: false, context: 32_000, requiresKey: false),
    ]

    public var allProviders: [String: Provider] {
        var all = Self.defaultProviders
        for (k, v) in providers ?? [:] { all[k] = v }
        return all
    }

    public static func load() -> Settings {
        let url = Paths.userConfig.appending(path: "settings.json")
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        do { return try JSONDecoder().decode(Settings.self, from: data) }
        catch {
            FileHandle.standardError.write(Data("[emmex] settings.json ignored: \(error)\n".utf8))
            return Settings()
        }
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.userConfig, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Paths.userConfig.appending(path: "settings.json"), options: .atomic)
    }
}
