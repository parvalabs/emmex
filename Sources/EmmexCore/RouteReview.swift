import Foundation
import FoundationModels

/// Offline review of routing decisions: a strong model judges, per turn, whether the tier that
/// answered was appropriate, given the prompt, what happened, and the tier definitions.
public enum RouteReviewer {
    public struct Verdict: Sendable { public var turn: Int; public var verdict: String; public var reason: String }

    public static func review(_ record: SessionRecord, with spec: ModelSpec) async throws -> [Verdict] {
        let session = try await Backends.makeSession(spec, tools: [], instructions: """
        You audit an AI coding agent's model routing. Tiers: local = \(TierGuide.local). \
        cheap = \(TierGuide.cheap). frontier = \(TierGuide.frontier). For each turn you get the \
        user's request, the tier and model that answered, and the outcome (tool calls, errors, \
        whether the user's next message looked like a correction). Judge whether the tier was \
        appropriate for the work required; over-routed means a cheaper tier would have handled \
        it well, under-routed means it needed a stronger tier. Prefer the cheapest capable tier. \
        Answer in exactly two lines: "verdict: appropriate|over-routed|under-routed" then "reason: <one sentence>".
        """)
        var out: [Verdict] = []
        for r in record.routes {
            let prompt = """
            Turn \(r.turn). Request: \(r.prompt)
            Answered by: tier=\(r.tier ?? "fixed") model=\(r.model)\(r.reason.map { " (router reason: \($0))" } ?? "")
            Outcome: \(r.toolCalls) tool calls, \(r.errors) errors, \(r.tokensOut) output tokens, \(r.durationMs / 1000)s\(r.followedByCorrection == true ? ", next user message looked like a correction" : "")
            """
            // Streaming path: the adapter's non-streaming respond with a token cap fails to parse.
            var text = ""
            for try await snap in session.streamResponse(to: prompt) { text = snap.content }
            var verdict = "?", reason = ""
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.lowercased().hasPrefix("verdict:") { verdict = l.dropFirst(8).trimmingCharacters(in: .whitespaces).lowercased() }
                else if l.lowercased().hasPrefix("reason:") { reason = l.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            }
            if !["appropriate", "over-routed", "under-routed"].contains(verdict) { verdict = ["over", "under"].first { text.lowercased().contains($0 + "-routed") }.map { $0 + "-routed" } ?? "appropriate" }
            out.append(.init(turn: r.turn, verdict: verdict, reason: reason))
        }
        return out
    }
}
