import ArgumentParser
import Foundation
import FoundationModels
import MlexCore
import MlexServer

@main struct Mlex: AsyncParsableCommand {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)   // interleave print() with FileHandle writes correctly
        await Self.main(nil)
    }
    static let configuration = CommandConfiguration(
        abstract: "mlex: local-first agent on Apple Foundation Models, MLX models, and Claude.",
        subcommands: [Models.self, Run.self, Chat.self, Sessions.self, WorktreesCmd.self, MCPCmd.self, MemoryCmd.self, Serve.self, Trust.self, Policy.self, SandboxCmd.self, RouteCmd.self],
        defaultSubcommand: Chat.self)
}

struct ModelOption: ParsableArguments {
    @Option(name: [.short, .long], help: "auto | system | pcc | claude:<name> | mlx:<hf-id>")
    var model: String = "system"
    @Option(name: .long, help: "Reasoning effort: off | low | medium | high (Claude effort, MLX thinking on/off).")
    var effort: String = "off"
    @Option(name: .long, help: "Permission level: ask | smart | full (default from settings, smart).")
    var permission: String?
    @Option(name: .long, help: "Session mode: chat (no tools) | code.")
    var mode: String = "code"
    func permissionLevel() throws -> PermissionLevel? {
        guard let permission else { return nil }
        guard let p = PermissionLevel(rawValue: permission) else { throw ValidationError("permission must be ask, smart, or full") }
        return p
    }
    func sessionMode() throws -> SessionMode {
        guard let m = SessionMode(rawValue: mode) else { throw ValidationError("mode must be chat or code") }
        return m
    }
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
                                                    subcommands: [List.self, Delete.self, Inspect.self, Fork.self, Export.self, Routes.self, Review.self], defaultSubcommand: List.self)
    struct Routes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which model answered each turn and how it went.")
        @Argument var id: String
        func run() async throws {
            guard let r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            if r.routes.isEmpty { print("no routing log (session predates routing logs or has no turns)"); return }
            func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s.padding(toLength: n, withPad: " ", startingAt: 0) }
            print("turn tier     model                   conf tools errs   out  time corr review        prompt")
            for x in r.routes {
                let conf = x.confidence.map { String(format: "%3d%%", Int($0 * 100)) } ?? "   -"
                let corr = x.followedByCorrection == true ? "YES" : (x.followedByCorrection == false ? "no" : "-")
                print("\(pad(String(x.turn), 4)) \(pad(x.tier ?? "fixed", 8)) \(pad(x.model, 23)) \(conf) \(pad(String(x.toolCalls), 5)) \(pad(String(x.errors), 4)) \(pad(String(x.tokensOut), 5)) \(pad("\(x.durationMs / 1000)s", 5)) \(pad(corr, 4)) \(pad(x.review ?? "-", 13)) \(x.prompt.prefix(48).replacingOccurrences(of: "\n", with: " "))")
                if let why = x.reason, !why.isEmpty { print("      router: \(why)") }
                if let rr = x.reviewReason, !rr.isEmpty { print("      review: \(rr)") }
            }
        }
    }
    struct Review: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask a strong model whether each turn's tier was appropriate; stores verdicts on the session.")
        @Argument var id: String
        @Option(name: .long, help: "Reviewer model spec (default claude:opus5_5).") var model: String = "claude:opus5_5"
        func run() async throws {
            guard var r = try SessionStore.find(id) else { throw ValidationError("no session matching \(id)") }
            guard !r.routes.isEmpty else { print("no routing log to review"); return }
            let verdicts = try await RouteReviewer.review(r, with: try ModelSpec(parsing: model))
            var counts: [String: Int] = [:]
            for v in verdicts {
                if let i = r.routes.firstIndex(where: { $0.turn == v.turn }) { r.routes[i].review = v.verdict; r.routes[i].reviewReason = v.reason }
                counts[v.verdict, default: 0] += 1
                print("turn \(v.turn): \(v.verdict) — \(v.reason)")
            }
            try SessionStore.save(r)
            print("summary: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
    }
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

// MARK: policy

struct Policy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the permission policy would decide for a command, without running it.")
    @Argument(parsing: .remaining) var command: [String]
    @Option(name: .long) var workspace: String?
    @Option(name: .long, help: "ask | smart | full") var level: String = "smart"
    func run() async throws {
        let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
        let engine = PolicyEngine(workspace: ws, cwd: ws, level: PermissionLevel(rawValue: level) ?? .smart)
        let cmd = command.joined(separator: " ")
        let d = await engine.decide(.init(id: "x", tool: "bash", summary: cmd, command: cmd, paths: []))
        switch d {
        case .allow(let why): print("ALLOW  \(why)")
        case .deny(let why): print("DENY   \(why)")
        case .ask(let why): print("ASK    \(why)")
        }
        print("always-allow suggestion: \(PolicyEngine.alwaysPattern(for: cmd))")
    }
}

// MARK: route (debug)

struct RouteCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Debug: show how the router would tier a prompt, without running it.")
    @Argument(parsing: .remaining) var prompt: [String]
    func run() async throws {
        let p = prompt.joined(separator: " ")
        let d = try await TierResolver.makeRouter().route(.init(prompt: p, recent: "", tools: []))
        let spec = await TierResolver.current().spec(for: d.tier)
        print("\(d.tier.rawValue) → \(spec)  (\(d.router), \(Int(d.confidence * 100))%) \(d.reason)")
    }
}

// MARK: sandbox (debug)

struct SandboxCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sandbox", abstract: "Debug: run a command under the mlex sandbox as a given permission level would, without the policy.")
    @Argument(parsing: .remaining) var command: [String]
    @Option(name: .long) var workspace: String?
    @Option(name: .long, help: "smart (allowlisted domains) | full (all domains) | none (no network)") var network: String = "smart"
    func run() async throws {
        let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
        let cmd = command.joined(separator: " ")
        var proxyURL: String? = nil; var port: UInt16? = nil; var token: String? = nil; var px: NetworkProxy? = nil
        if network != "none", let p = await SandboxRuntime.shared.proxyInstance() {
            token = p.register(.init(allowedDomains: NetworkDefaults.domains + Settings.load().network.allowedDomains, allowAll: network == "full"))
            proxyURL = p.url(token: token!); port = p.port; px = p
        }
        let sb = Sandbox(workspace: ws, cwd: ws, tempDir: await SandboxRuntime.shared.tempDir(session: "debug"), proxyPort: port)
        let (exe, args, env) = sb.arguments(for: cmd, proxyURL: proxyURL)
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.environment = env; p.currentDirectoryURL = ws
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        print(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
        if let token, let px { let d = px.denials(for: token); if !d.isEmpty { print("[proxy denied] " + d.map { "\($0.host): \($0.reason)" }.joined(separator: "; ")) }; px.unregister(token) }
        print("exit=\(p.terminationStatus)")
    }
}

// MARK: trust

struct Trust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Mark a workspace as trusted (its own scripts may run without asking in smart mode) or untrusted.")
    @Option(name: .long) var workspace: String?
    @Flag(name: .long) var revoke = false
    func run() async throws {
        let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
        WorkspaceTrust.set(ws, trusted: !revoke)
        print("\(ws.path): \(revoke ? "untrusted" : "trusted")")
    }
}

// MARK: serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the web UI on localhost (the same UI the Mac app shows).")
    @Option(name: .long, help: "Port (default 8765; 0 picks a free one).") var port: UInt16 = 8765
    @Option(name: .long, help: "Workspace to open (default: most recent).") var workspace: String?
    @Option(name: .long, help: "Serve web assets from this folder instead of the bundled ones (live editing).") var webRoot: String?
    @Flag(name: .long, help: "Open in the default browser.") var open = false

    func run() async throws {
        let app = try await MainActor.run { try WebApp(port: port, webRoot: webRoot.map { URL(fileURLWithPath: $0) }) }
        try await app.start()
        print("mlex web UI: \(app.url)")
        await MainActor.run {
            Task { @MainActor in
                await app.controller.start(autoOpen: workspace == nil)
                if let ws = workspace { app.controller.openWorkspace(URL(fileURLWithPath: ws)) }
            }
        }
        if open { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [app.url.absoluteString]) }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

// MARK: memory

struct MemoryCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory", abstract: "Facts remembered for a workspace.",
                                                    subcommands: [List.self, Search.self, Forget.self, Restore.self, Consolidate.self, Clear.self, Relate.self], defaultSubcommand: List.self)
    struct Relate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Debug: similarity and the on-device relation verdict for two facts.")
        @Argument var a: String
        @Argument var b: String
        func run() async throws {
            let va = await Embedder.shared.vector(for: a), vb = await Embedder.shared.vector(for: b)
            let sim = (va != nil && vb != nil) ? Embedder.cosine(va!, vb!) : 0
            let rel = try await MemoryConsolidator.relation([a, b])
            print(String(format: "cosine %.2f  relation %@", sim, rel))
        }
    }
    struct Restore: AsyncParsableCommand {
        @Argument var id: String
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            guard let f = await MemoryStore.shared.allFacts(workspace: ws).first(where: { $0.id.hasPrefix(id) }) else { throw ValidationError("no fact matching \(id)") }
            try await MemoryStore.shared.restore(f.id, workspace: ws); print("restored: \(f.text)")
        }
    }
    struct Consolidate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Merge overlapping facts with the on-device model; the newest wins on conflicts.")
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let merges = try await MemoryStore.shared.consolidate(workspace: ws)
            if merges.isEmpty { print("nothing to merge") }
            for m in merges { print("merged \(m.from.count) → \(m.merged)"); for f in m.from { print("    ← \(f)") } }
        }
    }
    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which facts would be retrieved for a prompt.")
        @Argument var prompt: String
        @Option(name: .long) var workspace: String?
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let hits = await MemoryStore.shared.relevant(to: prompt, workspace: ws)
            if hits.isEmpty { print("no relevant facts") }
            for f in hits { print("  [\(f.scope)/\(f.kind)] \(f.text)") }
        }
    }
    struct List: AsyncParsableCommand {
        @Option(name: .long) var workspace: String?
        @Flag(name: .long, help: "Include archived (expired or superseded) facts.") var archived = false
        func run() async throws {
            let ws = URL(fileURLWithPath: workspace ?? FileManager.default.currentDirectoryPath)
            let facts = archived ? await MemoryStore.shared.allFacts(workspace: ws) : await MemoryStore.shared.facts(workspace: ws)
            if facts.isEmpty { print("nothing remembered for \(ws.path)"); return }
            for f in facts.sorted(by: { $0.score() > $1.score() }) {
                let flag = f.archived ? (f.supersededBy != nil ? "superseded" : "archived  ") : String(format: "%5.2f     ", f.score())
                print("\(f.id.prefix(8))  \(flag)  \(f.scope.padding(toLength: 7, withPad: " ", startingAt: 0)) \(f.kind.padding(toLength: 10, withPad: " ", startingAt: 0))  \(f.uses)×  \(f.text)")
            }
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
        let agent = try await AgentSession(spec: try model.spec(), workspace: dir, mode: try model.sessionMode(), permission: try model.permissionLevel(), mcp: mcp, approver: nil, sink: Printer.print)
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
            agent = try await AgentSession(record: record, spec: override, mcp: mcp, approver: terminalApprover, sink: Printer.print)
            effort = record.effort
            print("resumed \(record.id.prefix(8)) “\(record.title)” (\(record.turns) turns)")
        } else {
            var cwd = ws
            if let worktree {
                let w = try Worktrees.add(repo: ws, branch: worktree)
                cwd = URL(fileURLWithPath: w.path)
                print("worktree \(worktree) at \(w.path)")
            }
            agent = try await AgentSession(spec: try model.spec(), workspace: ws, cwd: cwd, worktree: worktree, mode: try model.sessionMode(), permission: try model.permissionLevel(), mcp: mcp, approver: terminalApprover, sink: Printer.print)
        }
        let spec = agent.spec, dir = agent.cwd
        let commands = Commands(workspace: ws)
        print("mlex · \(spec) · \(dir) · \(agent.mode.rawValue) · permission \(agent.record.permission.rawValue) · effort \(effort.rawValue) · session \(agent.record.id.prefix(8)) · \(agent.toolNames.count) tools")
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
                for f in await MemoryStore.shared.facts(workspace: ws) { print("  [\(f.scope)/\(f.kind)] \(f.text)") }
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
                    agent = try await AgentSession(record: agent.record, spec: newSpec, mcp: mcp, approver: terminalApprover, sink: Printer.print)
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
                    agent = try await AgentSession(record: f, spec: nil, mcp: mcp, approver: terminalApprover, sink: Printer.print)
                    print("now in fork \(f.id.prefix(8)) (\(f.userTurns) user turns kept)")
                } catch { print("error: \(error)") }
                continue
            }
            if line == "/sessions" {
                for s in SessionStore.list(workspace: ws) { print("  \(s.id.prefix(8))  \(s.turns) turns  \(s.title)") }
                continue
            }
            if line.hasPrefix("/permission") {
                let v = line.dropFirst(11).trimmingCharacters(in: .whitespaces)
                if let p = PermissionLevel(rawValue: v) { await agent.setPermission(p); print("permission: \(p.rawValue)") } else { print("permission: ask | smart | full") }
                continue
            }
            if line == "/trust" { WorkspaceTrust.set(ws, trusted: true); print("workspace trusted: its own scripts may run without asking"); continue }
            if line == "/untrust" { WorkspaceTrust.set(ws, trusted: false); print("workspace untrusted"); continue }
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

/// Terminal approver: prints the request and reads y / n / a (always allow this command's first word).
let terminalApprover: Approver = { r in
    FileHandle.standardOutput.write(Data("\n  ⚠ \(r.tool): \(r.summary)\n    \(r.reason)\n    allow? [y/N/a=always] ".utf8))
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "n"
    if answer == "a", let cmd = r.command { return (true, PolicyEngine.alwaysPattern(for: cmd)) }
    return (answer == "y" || answer == "yes", nil)
}

enum Printer {
    nonisolated(unsafe) static var lineStart = true
    static let print: EventSink = { ev in
        switch ev {
        case .textDelta(let t):
            FileHandle.standardOutput.write(Data(t.utf8)); lineStart = t.hasSuffix("\n")
        case .toolCall(let name, let args):
            var shown = String(args.prefix(200))
            if name == "edit_file" || name == "write_file", let d = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: String], let path = d["path"] {
                let oldN = d["old"]?.split(separator: "\n").count, newN = (d["new"] ?? d["content"])?.split(separator: "\n").count ?? 0
                shown = name == "edit_file" ? "\(path) (-\(oldN ?? 0) +\(newN) lines)" : "\(path) (\(newN) lines)"
            }
            FileHandle.standardOutput.write(Data("\(lineStart ? "" : "\n")  ⚙ \(name): \(shown)\n".utf8)); lineStart = true
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
        case .approvalNeeded: break
        case .approvalResolved(_, let allowed, let layer):
            if ProcessInfo.processInfo.environment["MLEX_AUDIT"] != nil || !allowed {
                FileHandle.standardOutput.write(Data("\(lineStart ? "" : "\n")  \(allowed ? "✓" : "✗") \(layer)\n".utf8)); lineStart = true
            }
        }
    }
}
