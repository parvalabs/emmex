import Foundation

/// Agent Skills (agentskills.io): a directory with SKILL.md whose frontmatter has name and
/// description. Discovered from user and project dirs; listed to the model by name, description,
/// and path so it can read the full SKILL.md on demand, or forced with /skill:name.
public struct Skill: Identifiable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var path: URL              // the SKILL.md file
    public var modelInvocable: Bool
    public var id: String { name }
    public var directory: URL { path.deletingLastPathComponent() }

    public func body() -> String {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "" }
        return Frontmatter.split(text).body
    }
}

public enum Skills {
    /// Search roots, in priority order (first definition of a name wins).
    public static func roots(workspace: URL?) -> [URL] {
        var out: [URL] = []
        if let ws = workspace {
            out += [Paths.projectConfig(ws).appending(path: "skills"),
                    ws.appending(path: ".agents/skills"),
                    ws.appending(path: ".claude/skills")]
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        out += [Paths.userConfig.appending(path: "skills"),
                home.appending(path: ".agents/skills"),
                home.appending(path: ".claude/skills")]
        return out
    }

    public static func discover(workspace: URL?) -> [Skill] {
        var seen: Set<String> = []
        var out: [Skill] = []
        let fm = FileManager.default
        for root in roots(workspace: workspace) {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.lastPathComponent == "SKILL.md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let fm = Frontmatter.split(text).fields
                guard let desc = fm["description"], !desc.isEmpty else { continue }
                let name = fm["name"] ?? url.deletingLastPathComponent().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                out.append(.init(name: name, description: desc, path: url,
                                 modelInvocable: fm["disable-model-invocation"] != "true"))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The system-prompt section. Kept terse because the on-device model's window is small.
    public static func promptSection(_ skills: [Skill], limit: Int = 30) -> String? {
        let listed = skills.filter(\.modelInvocable).prefix(limit)
        guard !listed.isEmpty else { return nil }
        var s = "Skills available. When a task matches one, read its SKILL.md with read_file (absolute path) and follow it:\n"
        for k in listed { s += "- \(k.name): \(k.description.prefix(160)) → \(k.path.path)\n" }
        return s
    }
}

/// Prompt templates: markdown files whose name is the slash command. `$1…$N`, `$@`/`$ARGUMENTS`.
public struct PromptTemplate: Identifiable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var argumentHint: String?
    public var path: URL
    public var id: String { name }

    public func expand(_ args: String) -> String {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return "" }
        var body = Frontmatter.split(text).body
        let parts = Self.splitArgs(args)
        body = body.replacingOccurrences(of: "$ARGUMENTS", with: args).replacingOccurrences(of: "$@", with: args)
        for i in stride(from: 9, through: 1, by: -1) {
            body = body.replacingOccurrences(of: "$\(i)", with: i <= parts.count ? parts[i - 1] : "")
        }
        return body
    }

    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == " " { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func discover(workspace: URL?) -> [PromptTemplate] {
        var dirs: [URL] = []
        if let ws = workspace { dirs += [Paths.projectConfig(ws).appending(path: "prompts"), ws.appending(path: ".claude/commands")] }
        dirs += [Paths.userConfig.appending(path: "prompts"), URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/commands")]
        var seen: Set<String> = []
        var out: [PromptTemplate] = []
        for dir in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".md") {
                let name = String(f.dropLast(3))
                guard seen.insert(name).inserted, let text = try? String(contentsOf: dir.appending(path: f), encoding: .utf8) else { continue }
                let (fields, body) = Frontmatter.split(text)
                let desc = fields["description"] ?? body.split(separator: "\n").first.map(String.init) ?? ""
                out.append(.init(name: name, description: desc, argumentHint: fields["argument-hint"], path: dir.appending(path: f)))
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

/// Project context files appended to the system prompt, like pi and Claude Code do.
public enum ContextFiles {
    public static let names = ["AGENTS.md", "CLAUDE.md"]

    public static func load(workspace: URL?, cwd: URL?) -> String? {
        var chunks: [String] = []
        var dirs: [URL] = [Paths.userConfig]
        if let ws = workspace { dirs.append(Paths.projectConfig(ws)); dirs.append(ws) }
        if let cwd, cwd != workspace { dirs.append(cwd) }
        var seen: Set<String> = []
        for dir in dirs {
            for name in names + ["SYSTEM.md", "APPEND_SYSTEM.md"] {
                let url = dir.appending(path: name)
                guard seen.insert(url.path).inserted, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                chunks.append("## \(name) (\(dir.path))\n\(text.prefix(6000))")
            }
        }
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n\n")
    }
}

/// Minimal YAML-ish frontmatter: `---` block with `key: value` lines.
enum Frontmatter {
    static func split(_ text: String) -> (fields: [String: String], body: String) {
        guard text.hasPrefix("---") else { return ([:], text) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            fields[key] = value
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines))
    }
}

/// Slash-command expansion shared by the CLI and the app. Returns the prompt to send,
/// or nil if the line is not a known command.
public struct Commands {
    public var skills: [Skill]
    public var templates: [PromptTemplate]

    public init(workspace: URL?) {
        skills = Skills.discover(workspace: workspace)
        templates = PromptTemplate.discover(workspace: workspace)
    }

    public func expand(_ line: String) -> String? {
        guard line.hasPrefix("/") else { return nil }
        let head = line.dropFirst().split(separator: " ", maxSplits: 1)
        guard let cmd = head.first.map(String.init) else { return nil }
        let args = head.count > 1 ? String(head[1]) : ""
        if cmd.hasPrefix("skill:"), let k = skills.first(where: { $0.name == cmd.dropFirst(6) }) {
            let body = k.body()
            return "Follow this skill (from \(k.path.path)):\n\n\(body)\n\n" + (args.isEmpty ? "Apply it now." : "Request: \(args)")
        }
        if let t = templates.first(where: { $0.name == cmd }) { return t.expand(args) }
        return nil
    }
}
