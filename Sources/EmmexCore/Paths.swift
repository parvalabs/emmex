import Foundation
import CryptoKit

/// Where emmex keeps its state. Everything lives under Application Support except model weights,
/// worktrees and user config.
public enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    public static var appSupport: URL { supportBase.appending(path: "emmex") }
    /// Model weights, worktrees and classifier weights.
    public static var cacheRoot: URL { home.appending(path: ".cache/emmex") }
    public static var sessions: URL { appSupport.appending(path: "sessions") }
    public static var worktrees: URL { cacheRoot.appending(path: "worktrees") }
    public static var workspacesFile: URL { appSupport.appending(path: "workspaces.json") }
    /// User-level config dir: settings.json, skills, prompts, mcp.json.
    public static var userConfig: URL { home.appending(path: ".emmex") }

    /// Project-level config dir inside a workspace.
    public static func projectConfig(_ workspace: URL) -> URL { workspace.appending(path: ".emmex") }

    /// Stable short key for a workspace path, used as its sessions folder name.
    public static func key(for workspace: URL) -> String {
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Environment variables read by emmex (`EMMEX_*`).
public enum Env {
    public static func value(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }
}
