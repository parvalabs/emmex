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
        subcommands: [Models.self, Run.self, Chat.self],
        defaultSubcommand: Chat.self)
}

struct ModelOption: ParsableArguments {
    @Option(name: [.short, .long], help: "system | pcc | claude:<name> | mlx:<hf-id>")
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

// MARK: run / chat

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "One prompt, with tools, streamed to stdout.")
    @OptionGroup var model: ModelOption
    @Option(name: .long, help: "Working directory for tools (default: current).") var cwd: String?
    @Argument(parsing: .remaining) var prompt: [String]

    func run() async throws {
        let agent = try await AgentSession(spec: try model.spec(), cwd: cwd ?? FileManager.default.currentDirectoryPath, sink: Printer.print)
        try await agent.run(prompt.joined(separator: " "), effort: try model.effortLevel())
        print()
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive session. Empty line or /quit exits. /model <spec> switches model (transcript kept), /effort <level>, /save <file>.")
    @OptionGroup var model: ModelOption
    @Option(name: .long, help: "Working directory for tools (default: current).") var cwd: String?
    @Option(name: .long, help: "Resume from a saved transcript JSON.") var resume: String?

    func run() async throws {
        let spec = try model.spec()
        let dir = cwd ?? FileManager.default.currentDirectoryPath
        let transcript = try resume.map { try AgentSession.loadTranscript(from: URL(fileURLWithPath: $0)) }
        var agent = try await AgentSession(spec: spec, cwd: dir, transcript: transcript, sink: Printer.print)
        var effort = try model.effortLevel()
        print("mlex · \(spec) · \(dir) · effort \(effort.rawValue) (/effort <level> to change)")
        while true {
            FileHandle.standardOutput.write(Data("\n> ".utf8))
            guard let line = readLine(), !line.isEmpty, line != "/quit", line != "/exit" else { break }
            if line.hasPrefix("/model") {
                let v = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                do {
                    let newSpec = try ModelSpec(parsing: v)
                    agent = try await AgentSession(spec: newSpec, cwd: dir, transcript: agent.transcript, sink: Printer.print)
                    print("model: \(newSpec) · footprint \(SystemMemory.format(SystemMemory.footprint()))")
                } catch { print("error: \(error)") }
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
        }
    }
}
