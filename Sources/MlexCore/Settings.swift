import Foundation

/// User settings at ~/.mlex/settings.json. Only the router tiers exist so far.
public struct Settings: Codable, Sendable {
    public struct Routes: Codable, Sendable {
        public var local: String = "system"
        public var cheap: String = "claude:haiku"
        public var frontier: String = "claude:sonnet5"
    }
    public var routes = Routes()
    /// "ondevice" (default) or "jev" (TypeSafe Jev; needs a key in Keychain service `mlex-jev` or JEV_API_KEY).
    public var router: String = "ondevice"
    /// Remember facts from conversations and inject relevant ones.
    public var memory: Bool = true

    public static func load() -> Settings {
        let url = Paths.userConfig.appending(path: "settings.json")
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.userConfig, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Paths.userConfig.appending(path: "settings.json"), options: .atomic)
    }
}
