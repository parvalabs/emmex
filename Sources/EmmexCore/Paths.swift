import Foundation
import CryptoKit

/// Where emmex keeps its state. Everything lives under Application Support except model weights,
/// worktrees and user config. The product was called mlex, then emlex (2026-09-24), then emmex
/// (2026-09-27). The first access to any path moves the old folders to their new names and leaves
/// a symlink behind, so old git worktree links and saved session paths keep resolving.
public enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    public static var appSupport: URL { _ = migrated; return supportBase.appending(path: "emmex") }
    /// Model weights, worktrees and classifier weights.
    public static var cacheRoot: URL { _ = migrated; return home.appending(path: ".cache/emmex") }
    public static var sessions: URL { appSupport.appending(path: "sessions") }
    public static var worktrees: URL { cacheRoot.appending(path: "worktrees") }
    public static var workspacesFile: URL { appSupport.appending(path: "workspaces.json") }
    /// User-level config dir: settings.json, skills, prompts, mcp.json.
    public static var userConfig: URL { _ = migrated; return home.appending(path: ".emmex") }

    /// Earlier product names, newest first.
    public static let legacyNames = ["emlex", "mlex"]

    /// Project-level config dir inside a workspace: `.emmex`, or a pre-rename `.emlex` / `.mlex`
    /// when that is the only one present. Project folders are the user's files, so they are never moved.
    public static func projectConfig(_ workspace: URL) -> URL {
        let current = workspace.appending(path: ".emmex"), fm = FileManager.default
        if fm.fileExists(atPath: current.path) { return current }
        for name in legacyNames {
            let legacy = workspace.appending(path: ".\(name)")
            if fm.fileExists(atPath: legacy.path) { return legacy }
        }
        return current
    }

    /// Stable short key for a workspace path, used as its sessions folder name.
    public static func key(for workspace: URL) -> String {
        let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Old → new locations, newest old name first. A real old folder moves once when the new one
    /// does not exist yet; an old name that is already a symlink (an earlier migration) is left
    /// alone, so mlex → emlex → emmex keeps resolving as a chain.
    static func renames(home: URL, support: URL) -> [(URL, URL)] {
        legacyNames.flatMap { old in
            [(support.appending(path: old), support.appending(path: "emmex")),
             (home.appending(path: ".cache/\(old)"), home.appending(path: ".cache/emmex")),
             (home.appending(path: ".\(old)"), home.appending(path: ".emmex"))]
        }
    }

    /// Runs once per process, before the first path is handed out.
    static let migrated: Void = { migrateLegacy() }()

    @discardableResult
    public static func migrateLegacy(home: URL? = nil, support: URL? = nil, fileManager fm: FileManager = .default) -> [String] {
        var moved: [String] = []
        for (old, new) in renames(home: home ?? Self.home, support: support ?? supportBase) {
            let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
            guard fm.fileExists(atPath: old.path), !oldIsLink, !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                try? fm.createSymbolicLink(at: old, withDestinationURL: new)
                moved.append("\(old.path) → \(new.path)")
            } catch {
                FileHandle.standardError.write(Data("emmex: could not move \(old.path) to \(new.path): \(error)\n".utf8))
            }
        }
        return moved
    }
}

/// Environment variables: `EMMEX_*`, falling back to the pre-rename `EMLEX_*` and `MLEX_*` spellings.
public enum Env {
    public static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        if let v = env[name] { return v }
        guard name.hasPrefix("EMMEX_") else { return nil }
        let rest = name.dropFirst("EMMEX_".count)
        return env["EMLEX_" + rest] ?? env["MLEX_" + rest]
    }
}
