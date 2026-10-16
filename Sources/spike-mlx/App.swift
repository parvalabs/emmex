// Spike 3: can an 8B open model through the MLX bridge handle a routine git task with tools?
// Weights are pre-downloaded into ~/.cache/emmex/models/<org>/<name> (plain HF file layout).
import Foundation
import FoundationModels
import MLX
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import MLXLLM
import HuggingFace
import Tokenizers
import EmmexCore

@main struct App {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let modelID = Env.value("EMMEX_MLX_MODEL") ?? "mlx-community/Qwen3-8B-4bit"
        let modelsRoot = Paths.cacheRoot.appending(path: "models")
        let modelDir = modelsRoot.appending(path: modelID)

        // Scratch git repo with a feature branch behind main and an uncommitted change.
        let scratch = NSTemporaryDirectory() + "emmex-git-\(UUID().uuidString.prefix(6))"
        let setup = """
        set -e; mkdir -p \(scratch); cd \(scratch); git init -q -b main; git config user.email t@t; git config user.name t
        echo a > a.txt; git add .; git commit -qm 'init'
        git checkout -qb feature; echo f > f.txt; git add .; git commit -qm 'feature work'
        git checkout -q main; echo b > b.txt; git add .; git commit -qm 'main moves on'
        git checkout -q feature; echo pending > pending.txt
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", setup]
        try! p.run(); p.waitUntilExit()
        print("scratch repo: \(scratch)")

        do {
            let t0 = Date()
            let model = MLXLanguageModel(
                configuration: ModelConfiguration(directory: modelDir),
                capabilities: Env.value("EMMEX_REASONING") == "0" ? [.guidedGeneration, .toolCalling] : [.guidedGeneration, .toolCalling, .reasoning],
                weightsLocation: { _ in modelDir },
                load: { _, _ in
                    try await loadModelContainer(from: modelDir, using: #huggingFaceTokenizerLoader())
                })
            _ = try await LanguageModelSession(model: model).respond(to: "Say ok.", options: GenerationOptions(maximumResponseTokens: 4))
            print("model load + warmup: \(Int(Date().timeIntervalSince(t0)))s")
            if Env.value("EMMEX_MODE") == "warm" {
                // Does the GPU parking after idle slow the next turn, and does a tiny kernel
                // every 500 ms during the gap prevent it? Short cached turns isolate the stall.
                let session = LanguageModelSession(model: model, instructions: "You are terse.")
                func turn() async throws -> Double {
                    let t = Date()
                    _ = try await session.respond(to: "Reply with exactly: OK", options: GenerationOptions(maximumResponseTokens: 4))
                    return Date().timeIntervalSince(t)
                }
                _ = try await turn()
                for gap in [0.0, 2, 6, 15] {
                    for warm in [false, true] {
                        var times: [Double] = []
                        for _ in 0 ..< 3 {
                            let end = Date().addingTimeInterval(gap)
                            while Date() < end {
                                if warm { eval(MLXArray.ones([16]) + 1) }
                                try await Task.sleep(for: .milliseconds(warm ? 500 : 100))
                            }
                            times.append(try await turn())
                        }
                        print("gap \(Int(gap))s warm=\(warm): " + times.map { String(format: "%.3f", $0) }.joined(separator: " "))
                    }
                }
                return
            }
            if Env.value("EMMEX_MODE") == "restore" {
                // Prompt caches on disk: one turn, unload the model, the next turn. Run twice to
                // see a restart (the second run's first turn loads from disk).
                PromptCacheFiles.install()
                PromptCacheFiles.register(name: ModelConfiguration(directory: modelDir).name, modelDirectory: modelDir)
                let text = (1...150).map { "Preamble note \($0): the build of module \($0 % 17) passed after step \($0 * 3)." }.joined(separator: "\n")
                let session = LanguageModelSession(model: model, instructions: "You are a coding assistant. Reference material follows.\n" + text)
                func turn(_ label: String, _ n: Int) async throws {
                    let prompt = (1...60).map { "Turn \(n) note \($0): module \($0 % 17) passed after step \($0 * 3)." }.joined(separator: "\n") + "\nReply with exactly: OK"
                    let t = Date()
                    let r = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 8))
                    print("\(label): \(String(format: "%.2f", Date().timeIntervalSince(t)))s  prompt \(r.usage.input.totalTokenCount) (cached \(r.usage.input.cachedTokenCount))")
                }
                try await turn("turn 1", 1)
                await model.evict()
                try await turn("turn 2 after unload (includes weight reload)", 2)
                return
            }
            if Env.value("EMMEX_MODE") == "switch" {
                // Time to first token while alternating between sessions that share a long
                // preamble (like emmex's system prompt) and each grow their own history.
                func filler(_ tag: String, lines: Int) -> String {
                    (1...lines).map { "\(tag) note \($0): the build of module \($0 % 17) passed after step \($0 * 3)." }.joined(separator: "\n")
                }
                let preamble = "You are a coding assistant. Reference material follows.\n" + filler("Preamble", lines: 150)
                let sessions = ["A", "B"].map { LanguageModelSession(model: model, instructions: preamble + "\nYou are session \($0).") }
                var turn = [0, 0]
                for (i, s) in [0, 1, 0, 1, 0, 1].enumerated() {
                    turn[s] += 1
                    let prompt = filler("Session \(["A", "B"][s]) turn \(turn[s])", lines: 60) + "\nReply with exactly: OK"
                    // An 8-token reply makes the total almost all prefill.
                    let t = Date()
                    let r = try await sessions[s].respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 8))
                    let secs = Date().timeIntervalSince(t)
                    let cached = r.usage.input.cachedTokenCount, fed = r.usage.input.totalTokenCount - cached
                    print("step \(i + 1) session \(["A", "B"][s]) turn \(turn[s]): \(String(format: "%.2f", secs))s  prompt \(r.usage.input.totalTokenCount) (cached \(cached), fed \(fed))  => \(String(format: "%.0f", Double(fed) / secs)) tok/s")
                }
                return
            }
            if Env.value("EMMEX_MODE") == "bench" {
                func bench(_ label: String, tools: [any FoundationModels.Tool], reasoning: ContextOptions.ReasoningLevel? = nil) async throws {
                    let s = LanguageModelSession(model: model, tools: tools, instructions: "You are a helpful assistant.")
                    let t = Date()
                    let r = try await s.respond(to: "Write a 150-word paragraph about tide pools.",
                                                options: GenerationOptions(maximumResponseTokens: 200),
                                                contextOptions: ContextOptions(reasoningLevel: reasoning))
                    let secs = Date().timeIntervalSince(t)
                    let toks = r.usage.output.totalTokenCount + r.usage.output.reasoningTokenCount
                    print("\(label): \(String(format: "%.1f", secs))s  out=\(r.usage.output.totalTokenCount) reasoning=\(r.usage.output.reasoningTokenCount)  => \(String(format: "%.1f", Double(toks)/secs)) tok/s")
                }
                try await bench("plain, no tools", tools: [])
                // Forced tool call: measures grammar-constrained decoding of the call itself.
                do {
                    let s = LanguageModelSession(model: model, tools: [BashTool(ToolContext(cwd: scratch, report: { ev in if case .toolCall(_, let a) = ev { print("    [tool +\(Int(Date().timeIntervalSince(t0)))s] \(a.prefix(60))") } }))],
                                                 instructions: "Use the bash tool when asked to run a command.")
                    let t = Date()
                    let r = try await s.respond(to: "Run the command `echo hi` with the bash tool and tell me the output.", options: GenerationOptions(maximumResponseTokens: 300))
                    print("forced tool call: \(String(format: "%.1f", Date().timeIntervalSince(t)))s  out=\(r.usage.output.totalTokenCount) reasoning=\(r.usage.output.reasoningTokenCount)  -> \(r.content.prefix(60))")
                }
                // Structured output via schema: what the router and memory extractor would use.
                do {
                    let schema = try SchemaBuilder.object("Route", [
                        ("tier", "one of: local, cheap, frontier", SchemaBuilder.string),
                        ("reason", "short justification", SchemaBuilder.string)])
                    let s = LanguageModelSession(model: model, instructions: "Classify the user's request.")
                    let t = Date()
                    let r = try await s.respond(to: "Request: 'when was this file last modified?'", schema: schema, options: GenerationOptions(maximumResponseTokens: 200))
                    print("schema output: \(String(format: "%.1f", Date().timeIntervalSince(t)))s  out=\(r.usage.output.totalTokenCount) reasoning=\(r.usage.output.reasoningTokenCount)  -> \(r.content.jsonString.prefix(100))")
                }
                return
            }
            let tStart = Date()
            let session = LanguageModelSession(
                model: model,
                tools: [BashTool(ToolContext(cwd: scratch, report: { ev in let t = Int(Date().timeIntervalSince(tStart)); if case .toolCall(_, let a) = ev { print("  [tool +\(t)s] $ \(a)") } else if case .toolResult(_, let o) = ev { print("  [tool +\(t)s] \(o.replacingOccurrences(of: "\n", with: "⏎").prefix(160))") } }))],
                instructions: "You are a coding agent working inside a local git repository with no remote. Use the bash tool to act. Run ONE command per tool call, read its output, then decide the next command. Never use interactive commands (no -i). When the task is complete, report the output of `git log --oneline -3`.")
            let r = try await session.respond(to: "Rebase the current branch onto main, then commit all pending changes with a sensible message.")
            print("RESULT (\(Int(Date().timeIntervalSince(t0)))s total incl. load): \(r.content)")
            print("task time: \(Int(Date().timeIntervalSince(tStart)))s  usage: in=\(r.usage.input.totalTokenCount) out=\(r.usage.output.totalTokenCount) reasoning=\(r.usage.output.reasoningTokenCount)")
            let check = Process(); check.executableURL = URL(fileURLWithPath: "/bin/zsh")
            check.arguments = ["-c", "cd \(scratch) && git log --oneline -4 && git status --short && echo BRANCH=$(git branch --show-current)"]
            let pipe = Pipe(); check.standardOutput = pipe; try check.run(); check.waitUntilExit()
            print("--- ground truth:\n" + String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        } catch { print("ERROR: \(error)") }
    }
}
