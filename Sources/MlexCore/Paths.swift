import Foundation
import CryptoKit

/// Where mlex keeps its state. Everything lives under Application Support except model weights.
public enum Paths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "mlex")
    }
    public static var sessions: URL { appSupport.appending(path: "sessions") }
    public static var worktrees: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/mlex/worktrees") }
    public static var workspacesFile: URL { appSupport.appending(path: "workspaces.json") }
    /// User-level config dir: skills, mcp.json.
    public static var userConfig: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".mlex") }
    /// Project-level config dir inside a workspace.
    public static func projectConfig(_ workspace: URL) -> URL { workspace.appending(path: ".mlex") }

    /// Stable short key for a workspace path, used as its sessions folder name.
    public static func key(for workspace: URL) -> String {
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
