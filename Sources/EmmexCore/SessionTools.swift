import Foundation
import FoundationModels

extension SessionRecord {
    /// A new session that starts from this one's transcript, optionally cut before user turn
    /// `userTurn` (1-based). The fork keeps the workspace, cwd, worktree, model, and effort.
    public func forked(beforeUserTurn userTurn: Int? = nil) -> SessionRecord {
        var copy = SessionRecord(workspace: workspaceURL, cwd: cwdURL, worktree: worktree, model: spec, effort: effort)
        copy.title = "Fork of \(title)"
        var entries: [Transcript.Entry] = []
        var seenPrompts = 0
        for e in transcript {
            if case .prompt = e {
                seenPrompts += 1
                if let userTurn, seenPrompts >= userTurn { break }
            }
            entries.append(e)
        }
        copy.transcript = Transcript(entries: entries)
        copy.turns = max(0, min(turns, (userTurn ?? Int.max) - 1))
        return copy
    }

    /// Number of user prompts in the transcript.
    public var userTurns: Int { transcript.reduce(0) { if case .prompt = $1 { $0 + 1 } else { $0 } } }
}

/// Exports a session as a self-contained HTML page or as JSON.
public enum SessionExport {
    public static func html(_ r: SessionRecord) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func text(_ segs: [Transcript.Segment]) -> String {
            segs.compactMap { if case .text(let t) = $0 { t.content } else if case .structure(let s) = $0 { s.content.jsonString } else { nil } }.joined()
        }
        var body = ""
        var turn = 0
        let routes = Dictionary(uniqueKeysWithValues: r.routes.map { ($0.turn, $0) })
        for e in r.transcript {
            switch e {
            case .prompt(let p):
                let t = text(p.segments)
                if !t.hasPrefix("Summary of the conversation") { turn += 1 }
                body += "<div class=\"user\"><pre>\(esc(t))</pre></div>\n"
                if let x = routes[turn] {
                    body += "<div class=\"route\">→ \(esc(x.model))\(x.tier.map { " · \(esc($0))" } ?? "")\(x.confidence.map { String(format: " · %d%%", Int($0 * 100)) } ?? "")\(x.reason.map { " · \(esc($0))" } ?? "")\(x.review.map { " · review: \(esc($0))" } ?? "")</div>\n"
                }
            case .response(let x): body += "<div class=\"assistant\"><pre>\(esc(text(x.segments)))</pre></div>\n"
            case .toolCalls(let c): for call in c { body += "<div class=\"tool\">⚙ <b>\(esc(call.toolName))</b> <code>\(esc(String(call.arguments.jsonString.prefix(400))))</code></div>\n" }
            case .toolOutput(let o): body += "<details class=\"out\"><summary>\(esc(o.toolName)) output</summary><pre>\(esc(text(o.segments)))</pre></details>\n"
            default: break
            }
        }
        let df = ISO8601DateFormatter()
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(r.title))</title>
        <style>
        body{font:14px -apple-system,system-ui,sans-serif;max-width:860px;margin:32px auto;padding:0 20px;color:#1d1d1f;background:#fff}
        @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#e5e5ea}.user{background:#2c2c2e}.out pre,.tool{background:#2c2c2e}}
        h1{font-size:18px}.meta{color:#888;font-size:12px;margin-bottom:24px}
        .user{background:#eef2ff;border-radius:10px;padding:8px 12px;margin:16px 0 8px 80px}
        .assistant{margin:8px 80px 16px 0}.tool{font-size:12px;color:#666;margin:6px 0}
        .route{font-size:11px;color:#888;text-align:right;margin:2px 0 6px}
        .out{font-size:12px;margin:4px 0 8px 18px}.out pre{background:#f5f5f7;padding:8px;border-radius:6px;overflow:auto}
        pre{white-space:pre-wrap;word-break:break-word;margin:0;font:inherit}code{font-family:ui-monospace,Menlo,monospace;font-size:12px}
        </style></head><body>
        <h1>\(esc(r.title))</h1>
        <div class="meta">emmex · \(esc(r.model)) · \(esc(r.workspace))\(r.worktree.map { " · worktree \(esc($0))" } ?? "") · \(df.string(from: r.updatedAt)) · \(r.turns) turns</div>
        \(body)</body></html>
        """
    }

    public static func write(_ r: SessionRecord, to url: URL) throws {
        if url.pathExtension.lowercased() == "json" {
            try SessionStore.encoder.encode(r).write(to: url, options: .atomic)
        } else {
            try html(r).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
