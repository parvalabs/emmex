// Spike 1: does the Claude adapter expose prompt-cache usage across turns?
import Foundation
import FoundationModels
import ClaudeForFoundationModels
import MlexCore

@main struct App {
static func main() async {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        print("ANTHROPIC_API_KEY not set"); exit(2)
    }
    let cwd = FileManager.default.currentDirectoryPath
    let model = ClaudeLanguageModel(name: .sonnet5, auth: .apiKey(key))
    // Long instructions so a cache would be worth creating (Anthropic caches >= 1024 tokens on Sonnet).
    let filler = (1...60).map { "Rule \($0): Always be precise, terse and correct when answering about repository state." }.joined(separator: " ")
    let session = LanguageModelSession(model: model, tools: [BashTool(ToolContext(cwd: cwd, report: { ev in if case .toolCall(_, let a) = ev { print("  [tool] $ \(a)") } else if case .toolResult(_, let o) = ev { print("  [tool] \(o.replacingOccurrences(of: "\n", with: "⏎").prefix(160))") } }))],
                                       instructions: "You are mlex, a coding agent. \(filler)")
    
    func turn(_ p: String) async throws {
        let t0 = Date()
        let r = try await session.respond(to: p)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("TURN (\(ms)ms): \(r.content.prefix(200))")
        let u = r.usage
        print("  usage: in=\(u.input.totalTokenCount) cachedIn=\(u.input.cachedTokenCount) out=\(u.output.totalTokenCount) reasoning=\(u.output.reasoningTokenCount)")
    }
    
        do {
        try await turn("List the files in the current directory and count them.")
        try await turn("Which of those files is largest?")
        try await turn("Say 'done'.")
    } catch { print("ERROR: \(error)") }
}
}
