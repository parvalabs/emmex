import Foundation

/// Git worktrees for isolated sessions. Worktrees are created outside the repo, under
/// ~/.cache/mlex/worktrees/<repo>-<key>/<branch>, so the project tree stays clean.
public enum Worktrees {
    public struct Worktree: Sendable, Identifiable, Hashable {
        public var path: String
        public var branch: String?
        public var head: String
        public var isMain: Bool
        public var id: String { path }
    }

    public enum GitError: Error, CustomStringConvertible {
        case notARepo(String), failed(String)
        public var description: String {
            switch self {
            case .notARepo(let p): "\(p) is not inside a git repository"
            case .failed(let m): m
            }
        }
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GitError.failed(e.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return o
    }

    public static func repoRoot(of dir: URL) -> URL? {
        guard let out = try? git(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        return URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func list(repo: URL) throws -> [Worktree] {
        guard let root = repoRoot(of: repo) else { throw GitError.notARepo(repo.path) }
        let out = try git(["worktree", "list", "--porcelain"], in: root)
        var result: [Worktree] = []
        var cur: (path: String?, head: String?, branch: String?) = (nil, nil, nil)
        func flush() {
            if let p = cur.path { result.append(.init(path: p, branch: cur.branch, head: cur.head ?? "", isMain: p == root.path)) }
            cur = (nil, nil, nil)
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { flush(); cur.path = String(line.dropFirst(9)) }
            else if line.hasPrefix("HEAD ") { cur.head = String(line.dropFirst(5).prefix(7)) }
            else if line.hasPrefix("branch ") { cur.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if line.isEmpty { flush() }
        }
        flush()
        return result
    }

    public static func directory(repo root: URL, branch: String) -> URL {
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return Paths.worktrees.appending(path: "\(root.lastPathComponent)-\(Paths.key(for: root))").appending(path: safe)
    }

    /// Create a worktree on a new branch (from `base`, default HEAD), or reuse it if it exists.
    public static func add(repo: URL, branch: String, base: String? = nil) throws -> Worktree {
        guard let root = repoRoot(of: repo) else { throw GitError.notARepo(repo.path) }
        if let existing = try list(repo: root).first(where: { $0.branch == branch }) { return existing }
        let dir = directory(repo: root, branch: branch)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let branchExists = (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)) != nil
        var args = ["worktree", "add"]
        if !branchExists { args += ["-b", branch] }
        args.append(dir.path)
        if branchExists { args.append(branch) } else if let base { args.append(base) }
        try git(args, in: root)
        return .init(path: dir.path, branch: branch, head: "", isMain: false)
    }

    public static func remove(repo: URL, path: String, force: Bool = false) throws {
        guard let root = repoRoot(of: repo) else { throw GitError.notARepo(repo.path) }
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)
        try git(args, in: root)
    }
}
