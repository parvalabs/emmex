import Foundation
import CryptoKit

/// Where emlex keeps its state. Everything lives under Application Support except model weights,
/// worktrees and user config. The product was called mlex until 2026-09-24; the first access to
/// any path moves the old folders to their new names and leaves a symlink behind, so old git
/// worktree links and saved session paths keep resolving.
public enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    public static var appSupport: URL { _ = migrated; return supportBase.appending(path: "emlex") }
    /// Model weights, worktrees and classifier weights.
    public static var cacheRoot: URL { _ = migrated; return home.appending(path: ".cache/emlex") }
    public static var sessions: URL { appSupport.appending(path: "sessions") }
    public static var worktrees: URL { cacheRoot.appending(path: "worktrees") }
    public static var workspacesFile: URL { appSupport.appending(path: "workspaces.json") }
    /// User-level config dir: settings.json, skills, prompts, mcp.json.
    public static var userConfig: URL { _ = migrated; return home.appending(path: ".emlex") }

    /// Project-level config dir inside a workspace: `.emlex`, or a pre-rename `.mlex` when that is
    /// the only one present. Project folders are the user's files, so they are never moved.
    public static func projectConfig(_ workspace: URL) -> URL {
        let current = workspace.appending(path: ".emlex"), legacy = workspace.appending(path: ".mlex")
        let fm = FileManager.default
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    /// Stable short key for a workspace path, used as its sessions folder name.
    public static func key(for workspace: URL) -> String {
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Old → new locations, moved once when only the old one exists.
    static var renames: [(URL, URL)] {
        [(supportBase.appending(path: "mlex"), supportBase.appending(path: "emlex")),
         (home.appending(path: ".cache/mlex"), home.appending(path: ".cache/emlex")),
         (home.appending(path: ".mlex"), home.appending(path: ".emlex"))]
    }

    /// Runs once per process, before the first path is handed out.
    static let migrated: Void = { migrateLegacy() }()

    @discardableResult
    public static func migrateLegacy(fileManager fm: FileManager = .default) -> [String] {
        var moved: [String] = []
        for (old, new) in renames {
            let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
            guard fm.fileExists(atPath: old.path), !oldIsLink, !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
                moved.append("\(old.path) → \(new.path)")
            } catch {
                FileHandle.standardError.write(Data("emlex: could not move \(old.path) to \(new.path): \(error)\n".utf8))
            }
        }
        return moved
    }
}

/// Environment variables: `EMLEX_*`, falling back to the pre-rename `MLEX_*` spelling.
public enum Env {
    public static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env[name] { return v }
        return name.hasPrefix("EMLEX_") ? env[String(name.dropFirst())] : nil
    }
}
