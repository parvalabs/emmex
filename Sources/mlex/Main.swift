import ArgumentParser
import Foundation
import FoundationModels
import MlexCore

@main struct Mlex: AsyncParsableCommand {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)   // interleave print() with FileHandle writes correctly
        await Self.main(nil)
    }
    static let configuration = CommandConfiguration(
        abstract: "mlex: local-first agent on Apple Foundation Models, MLX models, and Claude.",
        subcommands: [Models.self, Run.self, Chat.self, Sessions.self, WorktreesCmd.self, MCPCmd.self, MemoryCmd.self],
        defaultSubcommand: Chat.self)
}

struct ModelOption: ParsableArguments {
    @Option(name: [.short, .long], help: "auto | system | pcc | claude:<name> | mlx:<hf-id>")
    var model: String = "system"
    @Option(name: .long, help: "Reasoning effort: off | low | medium | high (Claude effort, MLX thinking on/off).")
    var effort: String = "off"
    func effortLevel() throws -> Effort {
        guard let e = Effort(rawValue: effort) else { throw ValidationError("effort must be one of off, low, medium, high") }
        return e
    }
    func spec() throws -> ModelSpec { try ModelSpec(parsing: model) }
}

// MARK: models

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List, pull, or remove models.",
                                                    subcommands: [List.self, Pull.self, Remove.self],
                                                    defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show every backend and whether it is ready.")
        func run() async throws {
            for s in await Backends.status() {
                print("\(s.available ? "●" : "○") \(s.spec.padding(toLength: 40, withPad: " ", startingAt: 0)) \(s.detail)")
            }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download an MLX model from Hugging Face, e.g. mlx-community/Qwen3-8B-4bit. Ctrl-C stops; running pull again resumes.")
        @Argument var id: String
        func run() async throws {
            let store = ModelStore.shared
            if await store.isInstalled(id) { print("already installed: \(id)"); return }
            print(await store.isPartial(id) ? "resuming \(id) …" : "pulling \(id) …")
            let dest = try await store.pull(id) { fraction, detail in
                let pct = Int(fraction * 100)
                FileHandle.standardError.write(Data("\r  \(pct)% \(detail)          ".utf8))
            }
            print("\ninstalled at \(dest.path)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an installed MLX model.")
        @Argument var id: String
        func run() async throws {
            try await ModelStore.shared.remove(id)
            print("removed \(id)")
        }
    }
}

// MARK: sessions / worktrees

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sessions", abstract: "List or delete saved sessions.",
                                                    subcommands: [List.self, Delete.self, Inspect.self, Fork.self, Export.self], defaultSubcommand: List.self)
    struct Fork: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy a session into a new one, optionally cut before a user turn.")
        @Argument var id: String
        @Option(name: .long, help: "Cut before this user turn (1-based); default keeps everything.") var before: Int?
        func run() async throws {
            guard let r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            let f = r.forked(beforeUserTurn: before)
            try SessionStore.save(f)
            print("forked \(r.id.prefix(8)) → \(f.id.prefix(8)) “\(f.title)” (\(f.userTurns) user turns kept)")
        }
    }
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export a session to HTML (or JSON if the path ends in .json).")
        @Argument var id: String
        @Argument(help: "Output path; default <id>.html in the current directory.") var path: String?
        func run() async throws {
            guard let r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            let url = URL(fileURLWithPath: path ?? "\(r.id.prefix(8)).html")
            try SessionExport.write(r, to: url)
            print("exported to \(url.path)")
        }
    }
    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a session's transcript entries and probe which prefix the on-device tokenizer rejects.")
        @Argument var id: String
        func run() async throws {
            guard let r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            let entries = Array(r.transcript)
            func text(_ segs: [Transcript.Segment]) -> String { segs.compactMap { if case .text(let t) = $0 { t.content } else if case .structure(let st) = $0 { st.content.jsonString } else { "[attachment]" } }.joined() }
            for (i, e) in entries.enumerated() {
                switch e {
                case .instructions(let x): print("\(i) instructions tools=\(x.toolDefinitions.count) \(text(x.segments).prefix(70).replacingOccurrences(of: "\n", with: " "))")
                case .prompt(let x): print("\(i) prompt \(text(x.segments).prefix(90).replacingOccurrences(of: "\n", with: " "))")
                case .response(let x): print("\(i) response \(text(x.segments).prefix(90).replacingOccurrences(of: "\n", with: " "))")
                case .toolCalls(let x): print("\(i) toolCalls \(x.map { "\($0.toolName) \($0.arguments.jsonString.prefix(50))" })")
                case .toolOutput(let x): print("\(i) toolOutput \(x.toolName) \(text(x.segments).prefix(70).replacingOccurrences(of: "\n", with: " "))")
                case .reasoning: print("\(i) reasoning")
                @unknown default: print("\(i) other")
                }
            }
            print("--- tokenizer probe:")
            for n in 1...entries.count {
                do { let c = try await SystemLanguageModel.default.tokenCount(for: entries.prefix(n)); print("  prefix \(n): \(c) tokens") }
                catch { print("  prefix \(n): FAILS (\(error))"); break }
            }
        }
    }
    struct List: AsyncParsableCommand {
        @Option(name: .long, help: "Workspace folder (default: current).") var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let list = SessionStore.list(workspace: ws)
            if list.isEmpty { print("no sessions for \(ws.path)"); return }
            let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
            for s in list {
                let wt = s.worktree.map { " [\($0)]" } ?? ""
                print("\(s.id.prefix(8))  \(df.string(from: s.updatedAt))  \(s.model.padding(toLength: 22, withPad: " ", startingAt: 0))  \(s.turns) turns  \(s.title)\(wt)")
            }
        }
    }
    struct Delete: AsyncParsableCommand {
        @Argument(help: "Session id or unique prefix.") var id: String
        func run() async throws {
            guard let r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            try SessionStore.delete(r.id, workspace: r.workspaceURL)
            print("deleted \(r.id.prefix(8)) \(r.title)")
        }
    }
}

struct WorktreesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "worktrees", abstract: "List, add, or remove git worktrees for isolated sessions.",
                                                    subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)
    struct List: AsyncParsableCommand {
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            for w in try Worktrees.list(repo: ws) {
                print("\(w.isMain ? "main" : "    ")  \((w.branch ?? "(detached)").padding(toLength: 28, withPad: " ", startingAt: 0))  \(w.head)  \(w.path)")
            }
        }
    }
    struct Add: AsyncParsableCommand {
        @Argument(help: "Branch name for the worktree (created if missing).") var branch: String
        @Option(name: .long, help: "Base ref for a new branch (default: HEAD).") var base: String?
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let w = try Worktrees.add(repo: ws, branch: branch, base: base)
            print("worktree \(branch) at \(w.path)")
        }
    }
    struct Remove: AsyncParsableCommand {
        @Argument var branch: String
        @Flag(name: .long) var force = false
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            guard let w = try Worktrees.list(repo: ws).first(where: { $0.branch == branch }) else { throw ValidationError("no worktree for branch \(branch)") }
            try Worktrees.remove(repo: ws, path: w.path, force: force)
            print("removed \(w.path)")
        }
    }
}

// MARK: memory

struct MemoryCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory", abstract: "Facts remembered for a workspace.",
                                                    subcommands: [List.self, Forget.self, Clear.self], defaultSubcommand: List.self)
    struct List: AsyncParsableCommand {
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let facts = await MemoryStore.shared.facts(workspace: ws)
            if facts.isEmpty { print("nothing remembered for \(ws.path)"); return }
            for f in facts.sorted(by: { $0.createdAt > $1.createdAt }) { print("\(f.id.prefix(8))  \(f.kind.padding(toLength: 10, withPad: " ", startingAt: 0))  \(f.text)") }
        }
    }
    struct Forget: AsyncParsableCommand {
        @Argument var id: String
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            guard let f = await MemoryStore.shared.facts(workspace: ws).first(where: { $0.id.hasPrefix(id) }) else { throw ValidationError("no fact matching \(id)") }
            try await MemoryStore.shared.remove(f.id, workspace: ws); print("forgot: \(f.text)")
        }
    }
    struct Clear: AsyncParsableCommand {
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            try await MemoryStore.shared.clear(workspace: ws); print("cleared memory for \(ws.path)")
        }
    }
}

// MARK: mcp

struct MCPCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Show configured MCP servers (~/.mlex/mcp.json and .mlex/mcp.json) and their tools.")
    @Option(name: .long) var workspace: String?
    func run() async throws {
        let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
        let configs = MCPServerConfig.load(workspace: ws)
        if configs.isEmpty { print("no MCP servers configured; add {\"mcpServers\": {...}} to ~/.mlex/mcp.json or .mlex/mcp.json"); return }
        let host = MCPHost()
        await host.connect(workspace: ws)
        for s in await host.summary() {
            print("● \(s.server)  (\(s.info))")
            for t in s.tools { print("    \(t)") }
        }
        for (name, err) in await host.failures { print("○ \(name)  failed: \(err)") }
        await host.disconnectAll()
    }
}

// MARK: run / chat

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "One prompt, with tools, streamed to stdout.")
    @OptionGroup var model: ModelOption
    @Option(name: .long, help: "Working directory for tools (default: current).") var cwd: String?
    @Argument(parsing: .remaining) var prompt: [String]

    func run() async throws {
        let dir = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath)
        let mcp = MCPHost(); await mcp.connect(workspace: dir) { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
        let agent = try await AgentSession(spec: try model.spec(), workspace: dir, mcp: mcp, sink: Printer.print)
        agent.autosave = false
        try await agent.run(prompt.joined(separator: " "), effort: try model.effortLevel())
        await mcp.disconnectAll()
        print()
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive session, saved automatically. Empty line or /quit exits. /model <spec>, /effort <level>, /title <text>, /sessions.")
    @OptionGroup var model: ModelOption
    @Option(name: .long, help: "Workspace folder (default: current).") var workspace: String?
    @Option(name: .long, help: "Resume a saved session by id or prefix (model flag overrides its model).") var resume: String?
    @Option(name: .long, help: "Run in a git worktree on this branch (created if missing).") var worktree: String?

    func run() async throws {
        let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
        WorkspaceStore.touch(ws)
        var effort = try model.effortLevel()
        let mcp = MCPHost(); await mcp.connect(workspace: ws) { print($0) }
        var agent: AgentSession
        if let resume {
            guard let record = try SessionStore.find(resume) else { throw ValidationError("no session matching \(resume)") }
            let override = model.model == "system" ? nil : try model.spec()   // only override when --model was given explicitly
            agent = try await AgentSession(record: record, spec: override, mcp: mcp, sink: Printer.print)
            effort = record.effort
            print("resumed \(record.id.prefix(8)) “\(record.title)” (\(record.turns) turns)")
        } else {
            var cwd = ws
            if let worktree {
                let w = try Worktrees.add(repo: ws, branch: worktree)
                cwd = URL(fileURLWithPath: w.path)
                print("worktree \(worktree) at \(w.path)")
            }
            agent = try await AgentSession(spec: try model.spec(), workspace: ws, cwd: cwd, worktree: worktree, mcp: mcp, sink: Printer.print)
        }
        let spec = agent.spec, dir = agent.cwd
        let commands = Commands(workspace: ws)
        print("mlex · \(spec) · \(dir) · effort \(effort.rawValue) · session \(agent.record.id.prefix(8)) · \(commands.skills.count) skills · \(commands.templates.count) templates · \(agent.toolNames.count) tools")
        while true {
            FileHandle.standardOutput.write(Data("\n> ".utf8))
            guard let line = readLine(), !line.isEmpty, line != "/quit", line != "/exit" else { break }
            if line == "/skills" { for k in commands.skills { print("  /skill:\(k.name)  \(k.description.prefix(90))") }; continue }
            if line == "/prompts" { for t in commands.templates { print("  /\(t.name) \(t.argumentHint ?? "")  \(t.description.prefix(90))") }; continue }
            if line == "/compact" {
                do { if let sum = try await agent.compact() { print("summary:\n\(sum)") } else { print("nothing to compact") } } catch { print("error: \(error)") }
                continue
            }
            if line == "/context" {
                let (used, size) = await agent.contextUsage()
                print("context: \(used) / \(size) tokens"); continue
            }
            if line == "/memory" {
                for f in await MemoryStore.shared.facts(workspace: ws) { print("  [\(f.kind)] \(f.text)") }
                continue
            }
            if line == "/route" {
                if let d = agent.lastRoute { print("last route: \(d.tier.rawValue) via \(d.router) (\(Int(d.confidence * 100))%) → \(agent.effectiveSpec) \(d.reason)") } else { print("no routing yet (model must be auto)") }
                continue
            }
            if line == "/tools" { for t in agent.toolNames { print("  \(t)") }; continue }
            if let expanded = commands.expand(line) {
                do { try await agent.run(expanded, effort: effort); print() } catch { print("\nerror: \(error)") }
                continue
            }
            if line.hasPrefix("/model") {
                let v = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                do {
                    let newSpec = try ModelSpec(parsing: v)
                    try agent.save()
                    agent = try await AgentSession(record: agent.record, spec: newSpec, mcp: mcp, sink: Printer.print)
                    print("model: \(newSpec) · footprint \(SystemMemory.format(SystemMemory.footprint()))")
                } catch { print("error: \(error)") }
                continue
            }
            if line.hasPrefix("/title") {
                agent.rename(line.dropFirst(6).trimmingCharacters(in: .whitespaces)); print("title: \(agent.record.title)"); continue
            }
            if line.hasPrefix("/export") {
                let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: p.isEmpty ? "\(agent.record.id.prefix(8)).html" : p)
                do { try agent.save(); try SessionExport.write(agent.record, to: url); print("exported to \(url.path)") } catch { print("error: \(error)") }
                continue
            }
            if line.hasPrefix("/fork") {
                let n = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                do {
                    try agent.save()
                    let f = agent.record.forked(beforeUserTurn: n); try SessionStore.save(f)
                    agent = try await AgentSession(record: f, spec: nil, mcp: mcp, sink: Printer.print)
                    print("now in fork \(f.id.prefix(8)) (\(f.userTurns) user turns kept)")
                } catch { print("error: \(error)") }
                continue
            }
            if line == "/sessions" {
                for s in SessionStore.list(workspace: ws) { print("  \(s.id.prefix(8))  \(s.turns) turns  \(s.title)") }
                continue
            }
            if line.hasPrefix("/effort") {
                let v = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if let e = Effort(rawValue: v) { effort = e; print("effort: \(e.rawValue)") } else { print("effort: off | low | medium | high") }
                continue
            }
            if line.hasPrefix("/save") {
                let path = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: path.isEmpty ? "mlex-session.json" : path)
                try agent.save(to: url); print("saved \(url.path)"); continue
            }
            do { try await agent.run(line, effort: effort); print() }
            catch { print("\nerror: \(error)") }
        }
        await mcp.disconnectAll()
    }
}

enum Printer {
    nonisolated(unsafe) static var lineStart = true
    static let print: EventSink = { ev in
        switch ev {
        case .textDelta(let t):
            FileHandle.standardOutput.write(Data(t.utf8)); lineStart = t.hasSuffix("\n")
        case .toolCall(let name, let args):
            FileHandle.standardOutput.write(Data("\(lineStart ? "" : "\n")  ⚙ \(name): \(args.prefix(200))\n".utf8)); lineStart = true
        case .toolResult(_, let out):
            let firstLines = out.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n    ")
            FileHandle.standardOutput.write(Data("    \(firstLines)\(out.count > 400 ? "\n    …" : "")\n".utf8)); lineStart = true
        case .finished(let usage, _):
            if let u = usage, ProcessInfo.processInfo.environment["MLEX_USAGE"] != nil {
                FileHandle.standardOutput.write(Data("\n  [in=\(u.input.totalTokenCount) cached=\(u.input.cachedTokenCount) out=\(u.output.totalTokenCount) footprint=\(SystemMemory.format(SystemMemory.footprint()))]".utf8))
            }
        case .warning(let w):
            FileHandle.standardError.write(Data("warning: \(w)\n".utf8))
        case .info(let i):
            FileHandle.standardOutput.write(Data("\(lineStart ? "" : "\n")  ℹ \(i)\n".utf8)); lineStart = true
        }
    }
}
