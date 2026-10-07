import Foundation
import FoundationModels

/// What happens before a side-effecting tool runs.
public enum PermissionLevel: String, Codable, CaseIterable, Sendable {
    case ask      // every write and command asks
    case smart    // rules first, on-device classifier for the gray zone, ask for the rest
    case full     // nothing asks
}

/// Capability profile of a session.
public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case chat     // no tools; memory and skills still apply; cheap by default
    case code     // full tools in a workspace
}

/// A side-effecting tool call awaiting a decision.
public struct ToolRequest: Sendable, Identifiable {
    public var id: String
    public var tool: String
    public var summary: String          // what the user sees: the command, or "write path"
    public var command: String?         // for bash
    public var paths: [String]          // files touched, absolute
    public var reason: String = ""      // filled by the policy: why it asks / was allowed
    public init(id: String, tool: String, summary: String, command: String?, paths: [String], reason: String = "") {
        self.id = id; self.tool = tool; self.summary = summary; self.command = command; self.paths = paths; self.reason = reason
    }
}

public enum Decision: Sendable, Equatable { case allow(String), deny(String), ask(String) }   // payload: reason/layer

/// Commands that legitimately need the network; everything else runs with network denied.
public enum NetworkPolicy {
    static let heads: Set<String> = ["git", "npm", "npx", "pnpm", "yarn", "bun", "pip", "pip3", "uv", "uvx", "cargo", "go", "brew", "gem", "bundle", "swift", "xcodebuild", "curl", "wget", "gh", "docker", "kubectl", "aws", "mise", "poetry", "composer", "dotnet", "mvn", "gradle", "hf", "ollama"]
    public static func needsNetwork(_ cmd: String) -> Bool {
        PolicyEngine.split(cmd).contains { part in
            let words = PolicyEngine.stripWrappers(part.split(separator: " ").map(String.init))
            guard let h = words.first else { return false }
            return heads.contains(PolicyEngine.basename(h))
        }
    }
}

/// Deterministic rules, provenance, and the on-device classifier, in that order.
public actor PolicyEngine {
    public let workspace: URL
    public let cwd: URL
    public var level: PermissionLevel
    /// Files the harness itself wrote or edited in this session: safe to execute.
    var created: Set<String> = []
    var allowPatterns: [String]

    public init(workspace: URL, cwd: URL, level: PermissionLevel) {
        self.workspace = workspace; self.cwd = cwd; self.level = level
        allowPatterns = AllowList.load(workspace: workspace)
    }

    public func setLevel(_ l: PermissionLevel) { level = l }
    /// Extra network domains granted for this workspace (from .emmex/permissions.json).
    public var allowedDomains: [String] { AllowList.loadDomains(workspace: workspace) }
    public func recordCreated(_ path: String) { created.insert(Self.canonical(path)) }
    public func addAllowPattern(_ p: String) {
        let head = Self.basename(p.split(separator: " ").first.map(String.init) ?? "")
        guard !Self.neverPrefixApprove.contains(head), !allowPatterns.contains(p) else { return }
        allowPatterns.append(p); AllowList.save(allowPatterns, workspace: workspace)
    }

    // MARK: decision

    var recent: [String] = []

    public func decide(_ r: ToolRequest) async -> Decision {
        if level == .full { return .allow("full") }
        if r.tool != "bash" {
            // write_file / edit_file: inside the workspace is fine unless the path is protected.
            if let p = r.paths.first(where: Self.isProtectedPath) { return .ask("protected path: \(Self.protectedName(p))") }
            if r.paths.allSatisfy(inside) { return level == .ask ? .ask("edit inside workspace") : .allow("rule: edit inside workspace") }
            return .ask("edits outside the workspace")
        }
        guard let cmd = r.command else { return .ask("no command") }
        // Doom loop: the same command three times in a row is a stuck model, not a plan.
        recent.append(cmd); if recent.count > 3 { recent.removeFirst() }
        if recent.count == 3, Set(recent).count == 1 { recent.removeAll(); return .ask("same command repeated three times") }
        if let d = hardDeny(r) { return .ask("blocked by rule: \(d)") }
        if let p = Self.criticalDelete(cmd) { return .ask("delete on a critical path: \(p)") }
        if let p = Self.redirectTarget(cmd), Self.isProtectedPath(p) || !inside(p.hasPrefix("/") ? p : cwd.appending(path: p).path) { return .ask("redirect to \(p)") }
        if Self.isOpaque(cmd) { return .ask("opaque command (sh -c, eval, or command substitution)") }
        if matchesAllowList(cmd) { return .allow("always-allowed pattern") }
        if Self.isReadOnly(cmd) { return .allow("rule: read-only command") }
        // Before ask mode (the evals read ask mode to see which rule decided) and before provenance
        // (which allows a whole compound command because of one script in it).
        if let what = Self.publishesOrChangesGlobalState(cmd) { return .ask("publishes or changes global state: \(what)") }
        if level == .ask { return .ask("ask mode") }
        if let script = Self.executedScript(cmd) {
            let path = Self.canonical(script.hasPrefix("/") ? script : cwd.appending(path: script).path)
            if created.contains(path) { return .allow("provenance: script written by emmex this session") }
            if inside(path), WorkspaceTrust.isTrusted(workspace) { return .allow("provenance: script in trusted workspace") }
            return .ask("script not created by emmex and workspace not trusted")
        }
        if Self.touchesOutsideWorkspace(cmd, workspace: workspace, cwd: cwd) { return .ask("command references paths outside the workspace") }
        // Gray zone: the on-device model judges, and may only allow, never overrule a rule.
        switch await SafetyClassifier.classify(command: cmd, cwd: cwd.path) {
        case .safe(let why): return .allow("classifier: \(why)")
        case .review(let why): return .ask("classifier: \(why)")
        case .dangerous(let why): return .ask("classifier flagged: \(why)")
        }
    }

    // MARK: rules

    static let denyPatterns: [(String, NSRegularExpression)] = [
        ("sudo", try! NSRegularExpression(pattern: #"(^|[;&|]\s*)sudo\b"#)),
        ("recursive delete", try! NSRegularExpression(pattern: #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|-r\s+-f|-rf|-fr)\b"#)),
        ("download piped to a shell", try! NSRegularExpression(pattern: #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|)sh\b"#)),
        ("eval", try! NSRegularExpression(pattern: #"\beval\b"#)),
        ("base64 decode", try! NSRegularExpression(pattern: #"\bbase64\b.*\s(-d|--decode)\b"#)),
        ("world-writable chmod", try! NSRegularExpression(pattern: #"\bchmod\b.*\b777\b"#)),
        ("force push", try! NSRegularExpression(pattern: #"\bgit\s+push\b.*(--force|-f)\b"#)),
        ("history rewrite", try! NSRegularExpression(pattern: #"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)"#)),
        ("credentials", try! NSRegularExpression(pattern: #"(~|\$HOME|/Users/[^/]+)/\.(ssh|aws|gnupg|config/gh)\b|\bsecurity\s+(find|dump|export)|\.env\b"#)),
        ("disk or system", try! NSRegularExpression(pattern: #"\b(diskutil|mkfs|dd\s+if=|launchctl|killall|shutdown|reboot)\b"#)),
        ("command substitution of a download", try! NSRegularExpression(pattern: #"\$\(\s*(curl|wget)\b"#)),
    ]

    func hardDeny(_ r: ToolRequest) -> String? {
        guard let cmd = r.command else { return nil }
        let range = NSRange(cmd.startIndex..., in: cmd)
        for (name, re) in Self.denyPatterns where re.firstMatch(in: cmd, range: range) != nil { return name }
        return nil
    }

    /// Files that allow rules must never cover, inside or outside the workspace (Claude Code's
    /// protected-path idea): VCS and agent config, shell startup files, secrets.
    static let protectedNames: [String] = [".git/", ".emmex/", ".claude/", ".vscode/", ".husky/", ".env", ".npmrc", ".mcp.json", ".ssh/", ".aws/", ".gnupg/",
                                           ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", "id_rsa", "id_ed25519", ".pem", ".key"]
    static func isProtectedPath(_ p: String) -> Bool { protectedName(p) != nil }
    static func protectedName(_ p: String) -> String? {
        let path = canonical(p) + (p.hasSuffix("/") ? "/" : "")
        for n in protectedNames where path.contains("/" + n) || path.hasSuffix(n) { return n }
        return nil
    }

    /// `rm` aimed at /, $HOME, ~, the cwd or a parent, or an unset-variable glob like "$X"/*.
    static func criticalDelete(_ cmd: String) -> String? {
        for part in split(cmd) {
            let words = stripWrappers(part.split(separator: " ").map(String.init))
            guard let head = words.first, basename(head) == "rm" || basename(head) == "rmdir" else { continue }
            for arg in words.dropFirst() where !arg.hasPrefix("-") {
                let a = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if a == "/" || a == "~" || a == "~/" || a == "$HOME" || a == "$HOME/" || a == "." || a == ".." || a == "*" || a == "./" { return a }
                if a.range(of: #"^["']?\$\{?[A-Za-z_]+\}?["']?/\*?$"#, options: .regularExpression) != nil { return a + " (variable may be empty; use \"${VAR:?}\"/*)" }
                if let top = ["/Users", "/Applications", "/Library", "/System", "/usr", "/etc", "/var", "/private"].first(where: { a == $0 || a == $0 + "/" }) { return top }
                if a == NSHomeDirectory() || a == NSHomeDirectory() + "/" { return "home directory" }
            }
        }
        return nil
    }

    /// Publishing (`npm publish`, `git push`, `gh pr create`…), user-global installs, installs
    /// outside a virtualenv or vendor dir, and macOS defaults: effects that leave the project, which
    /// the 3B judge calls safe. Returns what matched.
    static func publishesOrChangesGlobalState(_ cmd: String) -> String? {
        var activated = false   // an earlier part ran `source <relative>/bin/activate`
        for part in split(cmd) {
            let raw = part.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }   // "npm" → npm
            var words = stripWrappers(Array(raw.drop(while: isAssignment)))   // NODE_ENV=production npm publish → npm publish
            let prefix = raw.dropLast(words.count)                            // the assignments and wrappers in front
            guard let head = words.first.map(basename) else { continue }
            if head == "source" || head == ".", let p = words.dropFirst().first, p.hasSuffix("/bin/activate"), isRelative(p) { activated = true }
            let exe = words[0]                                                // pip, .venv/bin/pip, or the python running -m pip
            if head.hasPrefix("python"), words.count > 2, words[1] == "-m", words[2] == "pip" { words.removeFirst(2) }   // python3 -m pip … → pip …
            let tool = basename(words[0]), sub = words.count > 1 ? words[1] : ""
            let what = "\(tool) \(sub)"
            if ["npm", "cargo"].contains(tool), sub == "publish" { return what }
            if tool == "gem", sub == "push" || sub == "publish" { return what }
            if tool == "twine", sub == "upload" { return what }
            if tool == "git", sub == "push" { return what }
            if tool == "gh", sub == "pr", words.count > 2, words[2] == "create" { return "gh pr create" }
            if ["pip", "pip3"].contains(tool), sub == "install", words.contains("--user") { return "\(what) --user" }
            if ["pip", "pip3"].contains(tool), sub == "install", !activated, !isVenvExecutable(exe) { return "pip install outside a virtualenv" }
            if tool == "bundle", sub == "install" || sub.isEmpty {
                let path = words.firstIndex(of: "--path").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil }
                    ?? words.first { $0.hasPrefix("--path=") }.map { String($0.dropFirst("--path=".count)) }
                    ?? prefix.first { $0.hasPrefix("BUNDLE_PATH=") }.map { String($0.dropFirst("BUNDLE_PATH=".count)) }
                if !words.contains("--deployment"), !(path.map(isRelative) ?? false) { return "bundle install outside a vendor dir" }
            }
            if tool == "npm", sub == "install" || sub == "i", words.contains("-g") || words.contains("--global") { return "\(what) --global" }
            if tool == "defaults", sub == "write" { return what }
        }
        return nil
    }

    /// `NAME=value` in front of a command: a shell variable assignment, not the executable.
    static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        let name = w[..<eq]
        return !name.first!.isNumber && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A path relative to the working directory that stays below it: no `/`, `~`, `$` or `..`.
    /// Quotes are trimmed first, so `--path="/usr/x"` still counts as absolute.
    static func isRelative(_ p: String) -> Bool {
        let p = p.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return !p.isEmpty && !p.hasPrefix("/") && !p.hasPrefix("~") && !p.hasPrefix("$") && !p.split(separator: "/").contains("..")
    }

    /// pip or Python in a relative virtualenv's bin directory: `.venv/bin/pip`, `venv/bin/python3`.
    static func isVenvExecutable(_ p: String) -> Bool {
        let parts = p.split(separator: "/")
        return parts.count >= 3 && parts[parts.count - 2] == "bin" && isRelative(p)
            && [".venv", "venv", ".env", "env"].contains(String(parts[parts.count - 3]))
            && ["pip", "pip3", "python", "python3"].contains(String(parts.last!))
    }

    /// Target of `>`/`>>`/`tee` if any.
    static func redirectTarget(_ cmd: String) -> String? {
        if let m = cmd.range(of: #"(?<![<>&])>{1,2}\s*([^\s&|;]+)"#, options: .regularExpression) {
            let t = String(cmd[m]).replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            if !t.hasPrefix("&") && !t.hasPrefix("/dev/") { return t }
        }
        if let m = cmd.range(of: #"\btee\s+(-a\s+)?([^\s&|;]+)"#, options: .regularExpression) {
            return String(cmd[m]).split(separator: " ").last.map(String.init)
        }
        return nil
    }

    /// Commands whose real effect is hidden from text rules.
    static func isOpaque(_ cmd: String) -> Bool {
        if cmd.range(of: #"\b(ba|z|)sh\s+-[a-zA-Z]*c\b"#, options: .regularExpression) != nil { return true }
        if cmd.contains("$(") || cmd.contains("`") || cmd.contains("${") { return true }
        return false
    }

    /// Wrappers that do not change what a command does: strip before looking at the head token.
    static let wrappers: Set<String> = ["timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin", "noglob", "env", "caffeinate"]
    static func stripWrappers(_ words: [String]) -> [String] {
        var w = words
        while let head = w.first {
            if wrappers.contains(basename(head)) {
                w.removeFirst()
                // drop the wrapper's own flags/values (timeout 10, nice -n 5, env FOO=bar)
                while let n = w.first, n.hasPrefix("-") || n.contains("=") || Int(n) != nil { w.removeFirst() }
            } else { break }
        }
        return w
    }
    static func basename(_ s: String) -> String { s.contains("/") ? String(s.split(separator: "/").last ?? "") : s }

    /// How many leading tokens identify a command, for "always allow" suggestions:
    /// `git status --porcelain` → `git status *`, `npm run build -- --x` → `npm run build *`.
    static let arity: [String: Int] = ["git": 2, "npm run": 3, "npm": 2, "pnpm": 2, "yarn": 2, "docker compose": 3, "docker": 2, "cargo": 2, "swift": 2, "xcodebuild": 1, "make": 1, "python": 1, "pip": 2, "brew": 2, "gh": 2, "kubectl": 2]
    public static func alwaysPattern(for cmd: String) -> String {
        let words = stripWrappers(split(cmd).first?.split(separator: " ").map(String.init) ?? [])
        guard !words.isEmpty else { return cmd }
        let two = words.prefix(2).joined(separator: " ")
        let n = arity[two] ?? arity[basename(words[0])] ?? 1
        return words.prefix(n).joined(separator: " ") + " *"
    }
    /// Never let an allow pattern cover these: they take arbitrary commands as arguments.
    static let neverPrefixApprove: Set<String> = ["find", "xargs", "sh", "bash", "zsh", "env", "eval", "sudo", "watch", "flock", "time", "timeout", "nohup", "nice"]

    static let readOnlyHeads: Set<String> = ["ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "pwd", "echo", "which", "file", "stat", "du", "df", "date", "whoami", "env", "printenv", "tree", "diff", "sort", "uniq", "cut", "awk", "sed", "jq", "less", "more", "basename", "dirname", "realpath", "type", "test", "true", "xargs", "column", "nl", "od", "strings", "md5", "shasum", "sw_vers", "uname", "sysctl"]
    static let readOnlyGit: Set<String> = ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "ls-remote", "fetch", "blame", "describe", "tag", "stash list", "worktree list", "config --get"]

    /// Every simple command in a pipeline / list must be read-only, and nothing may redirect to a file.
    static func isReadOnly(_ cmd: String) -> Bool {
        if cmd.range(of: #"(^|[^<>])>(?!&)"#, options: .regularExpression) != nil { return false }     // > or >> to a file
        for part in split(cmd) {
            let words = stripWrappers(part.split(separator: " ").map(String.init)).map { $0 == $0.uppercased() && $0.contains("=") ? "" : $0 }.filter { !$0.isEmpty }
            guard let head0 = words.first else { continue }
            let head = basename(head0)
            if head == "git" {
                let sub = words.dropFirst().joined(separator: " ")
                guard readOnlyGit.contains(where: { sub == $0 || sub.hasPrefix($0 + " ") }) else { return false }
            } else if head == "sed" {
                if words.contains("-i") || words.contains(where: { $0.hasPrefix("-i") }) { return false }
            } else if head == "find" {
                if words.contains("-delete") || words.contains("-exec") { return false }
            } else if head == "xargs" {
                return false
            } else if !readOnlyHeads.contains(head) { return false }
        }
        return true
    }

    /// Split on ; && || | into simple commands, ignoring quotes.
    static func split(_ cmd: String) -> [String] {
        var parts: [String] = [], cur = "", quote: Character? = nil
        var it = cmd.makeIterator(); var prev: Character? = nil
        while let ch = it.next() {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; prev = ch; continue }
            if ch == "\"" || ch == "'" { quote = ch; cur.append(ch); prev = ch; continue }
            if ch == ";" || ch == "|" || (ch == "&" && prev == "&") { if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur.trimmingCharacters(in: .whitespaces)) }; cur = ""; prev = ch; continue }
            if ch == "&" { prev = ch; continue }
            cur.append(ch); prev = ch
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// `./script.sh`, `bash x.sh`, `python y.py`, `swift z.swift`, `node w.js` → the script path.
    static func executedScript(_ cmd: String) -> String? {
        for part in split(cmd) {
            let words = stripWrappers(part.split(separator: " ").map(String.init))
            guard let head = words.first else { continue }
            if head.hasPrefix("./") || head.hasPrefix("../") { return head }
            if ["bash", "sh", "zsh", "python", "python3", "node", "swift", "ruby", "perl"].contains(basename(head)) {
                if let arg = words.dropFirst().first(where: { !$0.hasPrefix("-") }), arg.contains(".") || arg.contains("/") { return arg }
            }
        }
        return nil
    }

    static func touchesOutsideWorkspace(_ cmd: String, workspace: URL, cwd: URL) -> Bool {
        let ws = workspace.standardizedFileURL.path, wt = cwd.standardizedFileURL.path
        let re = try! NSRegularExpression(pattern: #"(~|/Users/[^\s'"]+|/private/[^\s'"]+|/tmp/[^\s'"]+|/etc/[^\s'"]*|/usr/[^\s'"]*|/var/[^\s'"]+)"#)
        for m in re.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) {
            let p = String(cmd[Range(m.range, in: cmd)!])
            let abs = p.hasPrefix("~") ? NSHomeDirectory() + p.dropFirst() : p
            if abs.hasPrefix(ws) || abs.hasPrefix(wt) || abs.hasPrefix(NSTemporaryDirectory()) || abs.hasPrefix("/usr/bin") || abs.hasPrefix("/usr/local") || abs.hasPrefix("/usr/share") { continue }
            return true
        }
        return false
    }

    func inside(_ path: String) -> Bool {
        let p = Self.canonical(path)
        return p.hasPrefix(Self.canonical(workspace.path)) || p.hasPrefix(Self.canonical(cwd.path))
    }

    /// Standardized absolute path with symlinks resolved. For a path that does not exist yet,
    /// resolve its nearest existing ancestor and re-append the rest, so a new file inside a
    /// symlinked workspace (/tmp → /private/tmp) still compares equal to the workspace.
    static func canonical(_ p: String) -> String {
        // Foundation's resolvingSymlinksInPath deliberately keeps /tmp and /var unresolved; the
        // kernel (and Seatbelt) see /private/tmp and /private/var, so use realpath(3).
        func real(_ path: String) -> String {
            guard let r = realpath(path, nil) else { return path }
            defer { free(r) }
            return String(cString: r)
        }
        let url = URL(fileURLWithPath: p).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return real(url.path) }
        var dir = url.deletingLastPathComponent(); var tail = [url.lastPathComponent]
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { tail.insert(dir.lastPathComponent, at: 0); dir = dir.deletingLastPathComponent() }
        return tail.reduce(URL(fileURLWithPath: real(dir.path))) { $0.appending(path: $1) }.path
    }

    /// Allow rules must cover every subcommand of a compound command (deny/ask match any).
    func matchesAllowList(_ cmd: String) -> Bool {
        let parts = Self.split(cmd)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let words = Self.stripWrappers(part.split(separator: " ").map(String.init))
            if let h = words.first, Self.neverPrefixApprove.contains(Self.basename(h)) { return false }
            return allowPatterns.contains { pattern in
                pattern.hasSuffix(" *") ? (part == String(pattern.dropLast(2)) || part.hasPrefix(String(pattern.dropLast()))) : part == pattern
            }
        }
    }
}

/// Per-workspace "always allow" command patterns (`git commit *`), at <workspace>/.emmex/permissions.json.
enum AllowList {
    static func url(_ ws: URL) -> URL { Paths.projectConfig(ws).appending(path: "permissions.json") }
    static func load(workspace: URL) -> [String] {
        (try? Data(contentsOf: url(workspace))).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) }?["allow"] ?? []
    }
    static func loadDomains(workspace: URL) -> [String] {
        (try? Data(contentsOf: url(workspace))).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) }?["allowedDomains"] ?? []
    }
    static func save(_ patterns: [String], workspace: URL) {
        try? FileManager.default.createDirectory(at: url(workspace).deletingLastPathComponent(), withIntermediateDirectories: true)
        var all = (try? Data(contentsOf: url(workspace))).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        all["allow"] = patterns
        try? JSONEncoder().encode(all).write(to: url(workspace), options: .atomic)
    }
}

/// Workspaces whose own scripts may run without asking (set once, like project trust in pi).
public enum WorkspaceTrust {
    static var url: URL { Paths.appSupport.appending(path: "trust.json") }
    static func load() -> Set<String> { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }.map(Set.init) ?? [] }
    public static func isTrusted(_ ws: URL) -> Bool { load().contains(ws.standardizedFileURL.path) }
    public static func set(_ ws: URL, trusted: Bool) {
        var s = load(); if trusted { s.insert(ws.standardizedFileURL.path) } else { s.remove(ws.standardizedFileURL.path) }
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(s).sorted()).write(to: url, options: .atomic)
    }
}

/// The on-device model as a safety judge for commands the rules did not decide. Output is an
/// enum, so instructions hidden inside a command cannot steer it.
public enum SafetyClassifier {
    public enum Verdict { case safe(String), review(String), dangerous(String) }

    public static let safeMeans = "builds, tests, formatting, git commits on the current branch, creating or editing files inside the project, package installs into the project"
    public static let reviewMeans = "network calls, installs outside the project, anything touching files outside the project, unfamiliar tools, long-running servers"
    public static let dangerousMeans = "deleting outside the project, privilege escalation, sending files or secrets anywhere, disabling security"
    public static let instructions = """
    You judge whether a shell command is safe for an AI coding agent to run automatically \
    inside a software project directory. safe: \(safeMeans). review: \(reviewMeans). \
    dangerous: \(dangerousMeans). When unsure, answer review.
    """

    public static func classify(command: String, cwd: String) async -> Verdict {
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Safety", properties: [
                .init(name: "verdict", description: "safe: reversible, local to the project, no data leaves the machine; review: could modify things beyond the project or is unclear; dangerous: destructive, privileged, or exfiltrating",
                      schema: SchemaBuilder.choice("Verdict", ["safe", "review", "dangerous"])),
                .init(name: "reason", description: "One short clause", schema: SchemaBuilder.string),
            ]), dependencies: [])
            let session = LanguageModelSession(model: .default, instructions: instructions)
            let r = try await session.respond(to: "Working directory: \(cwd)\nCommand: \(command.prefix(600))", schema: schema, options: GenerationOptions(maximumResponseTokens: 60))
            let v = (try? r.content.value(String.self, forProperty: "verdict")) ?? "review"
            let why = (try? r.content.value(String.self, forProperty: "reason")) ?? ""
            switch v { case "safe": return .safe(why); case "dangerous": return .dangerous(why); default: return .review(why) }
        } catch { return .review("classifier unavailable") }
    }
}
