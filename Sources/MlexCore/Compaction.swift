import Foundation
import FoundationModels

/// Keeps a conversation inside the model's context window. Older entries are folded into a
/// summary by the Apple on-device model (free, private, works offline) and replaced with a
/// single prompt/response pair; the most recent entries are kept verbatim.
public enum Compactor {
    public struct Result: Sendable { public var summary: String; public var tokensBefore: Int; public var tokensAfter: Int; public var dropped: Int }

    static let summaryPrompt = """
    Summarize the conversation below for an AI coding agent that will continue it. Use these \
    sections with short bullets: Goal, Progress (done / in progress / blocked), Key decisions, \
    Files touched, Next steps. Keep exact names, paths, commands, and values. Under 300 words.
    """

    /// Context window for a backend. Apple models report theirs; Claude's is 200k; MLX models
    /// declare it in config.json (capped, since KV memory grows with it).
    public static func contextSize(for spec: ModelSpec) async -> Int {
        switch spec {
        case .system: return SystemLanguageModel.default.contextSize
        case .pcc: return (try? await PrivateCloudComputeLanguageModel().contextSize) ?? 32_768
        case .claude: return 200_000
        case .mlx(let id): return await ModelStore.shared.contextLength(for: id)
        }
    }

    /// Tokens in the transcript: exact for the on-device model, otherwise the last turn's
    /// reported input tokens, otherwise a character-based estimate.
    public static func tokensUsed(session: LanguageModelSession, spec: ModelSpec, lastInputTokens: Int?) async -> Int {
        if spec == .system, let n = try? await SystemLanguageModel.default.tokenCount(for: session.transcript) { return n }
        if let lastInputTokens, lastInputTokens > 0 { return lastInputTokens }
        return session.transcript.map(render).reduce(0) { $0 + $1.count } / 4
    }

    /// Whether the transcript is close enough to the window to compact before the next turn.
    /// MLEX_COMPACT_RESERVE overrides the reserve fraction (useful for testing).
    public static func shouldCompact(session: LanguageModelSession, spec: ModelSpec, lastInputTokens: Int?, reserve: Double = 0.25) async -> (Bool, Int, Int) {
        let reserve = ProcessInfo.processInfo.environment["MLEX_COMPACT_RESERVE"].flatMap(Double.init) ?? reserve
        let size = await contextSize(for: spec)
        let used = await tokensUsed(session: session, spec: spec, lastInputTokens: lastInputTokens)
        guard size > 0 else { return (false, used, size) }
        return (Double(used) > Double(size) * (1 - reserve), used, size)
    }

    /// Fold everything except the instructions and the last `keepRecent` entries into a summary.
    public static func compact(transcript: Transcript, keepRecent: Int = 6) async throws -> (Transcript, String, Int) {
        var instructions: Transcript.Entry?
        var rest: [Transcript.Entry] = []
        for e in transcript {
            if case .instructions = e, instructions == nil { instructions = e } else { rest.append(e) }
        }
        let keep = keepRecent < rest.count ? Array(rest.suffix(keepRecent)) : rest
        let old = rest.dropLast(keep.count)
        guard !old.isEmpty else { return (transcript, "", 0) }
        let summary = try await summarize(Array(old))
        var entries: [Transcript.Entry] = []
        if let instructions { entries.append(instructions) }
        entries.append(.prompt(.init(segments: [.text(.init(content: "Summary of the conversation so far (earlier turns were compacted):\n\n\(summary)"))])))
        entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: "Understood. I will continue from this summary."))])))
        entries += keep
        return (Transcript(entries: entries), summary, old.count)
    }

    /// Incremental fold so any length of history fits the on-device model's window.
    public static func summarize(_ entries: [Transcript.Entry]) async throws -> String {
        let chunks = chunk(entries.map(render), maxChars: 9000)
        var summary = ""
        for c in chunks {
            let session = LanguageModelSession(model: .default, instructions: summaryPrompt)
            let prompt = summary.isEmpty ? c : "Existing summary:\n\(summary)\n\nContinue with these later turns:\n\(c)"
            summary = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 600)).content
        }
        return summary
    }

    static func render(_ e: Transcript.Entry) -> String {
        func text(_ segs: [Transcript.Segment]) -> String {
            segs.compactMap { if case .text(let t) = $0 { t.content } else if case .structure(let s) = $0 { s.content.jsonString } else { nil } }.joined()
        }
        switch e {
        case .prompt(let p): return "User: \(text(p.segments))"
        case .response(let r): return "Assistant: \(text(r.segments))"
        case .toolCalls(let c): return "Tool calls: " + c.map { "\($0.toolName)(\($0.arguments.jsonString.prefix(200)))" }.joined(separator: "; ")
        case .toolOutput(let o): return "Tool \(o.toolName) output: \(text(o.segments).prefix(600))"
        case .instructions, .reasoning: return ""
        @unknown default: return ""
        }
    }

    static func chunk(_ lines: [String], maxChars: Int) -> [String] {
        var out: [String] = [], cur = ""
        for l in lines where !l.isEmpty {
            if cur.count + l.count > maxChars, !cur.isEmpty { out.append(cur); cur = "" }
            cur += l + "\n"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
