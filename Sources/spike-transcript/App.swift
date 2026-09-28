// Spike 2: loop control. Run a tool call, then rewrite the transcript
// (prune a tool output, inject a memory fact) and resume in a new session.
import Foundation
import FoundationModels
import EmmexCore

func text(_ segs: [Transcript.Segment]) -> String {
    segs.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
}

func describe(_ t: Transcript) {
    for e in t {
        switch e {
        case .instructions(let i): print("  [instructions] \(i.segments.count) seg, \(i.toolDefinitions.count) tools")
        case .prompt(let p): print("  [prompt] \(text(p.segments).prefix(80))")
        case .toolCalls(let c): print("  [toolCalls] \(c.map { $0.toolName })")
        case .toolOutput(let o): print("  [toolOutput:\(o.toolName)] \(text(o.segments).replacingOccurrences(of: "\n", with: "⏎").prefix(80))")
        case .response(let r): print("  [response] \(text(r.segments).prefix(80))")
        case .reasoning: print("  [reasoning]")
        @unknown default: print("  [other]")
        }
    }
}

@main struct App {
    static func main() async {
        let scratch = NSTemporaryDirectory() + "emmex-spike-\(UUID().uuidString.prefix(6))"
        try! FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        for n in ["alpha.txt", "beta.txt", "gamma.txt"] {
            FileManager.default.createFile(atPath: scratch + "/" + n, contents: Data("x".utf8))
        }
        do {
            let tools: [any Tool] = [BashTool(ToolContext(cwd: scratch, report: { ev in if case .toolCall(_, let a) = ev { print("  [tool] $ \(a)") } else if case .toolResult(_, let o) = ev { print("  [tool] \(o.replacingOccurrences(of: "\n", with: "⏎").prefix(160))") } }))]
            let s1 = LanguageModelSession(tools: tools, instructions: "You are a terse coding agent. Use the bash tool to inspect the working directory when asked about it.")
            let t0 = Date()
            let r1 = try await s1.respond(to: "How many .txt files are in the working directory? Use ls.")
            print("A1 (\(Int(Date().timeIntervalSince(t0)*1000))ms): \(r1.content)")
            print("--- transcript after turn 1:"); describe(s1.transcript)

            var entries: [Transcript.Entry] = []
            for e in s1.transcript {
                if case .toolOutput(let o) = e {
                    entries.append(.toolOutput(.init(id: o.id, toolName: o.toolName, segments: [.text(.init(content: "[output pruned by emmex]"))])))
                } else { entries.append(e) }
            }
            entries.append(.prompt(.init(segments: [.text(.init(content: "Memory note: the project codename is PELICAN."))])))
            entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: "Noted."))])))

            let s2 = LanguageModelSession(tools: tools, transcript: Transcript(entries: entries))
            let t1 = Date()
            let r2 = try await s2.respond(to: "What is the project codename, and how many .txt files did you find earlier? One line.")
            print("A2 (\(Int(Date().timeIntervalSince(t1)*1000))ms): \(r2.content)")
            print("--- transcript after resume:"); describe(s2.transcript)
            print("PASS: transcript rewrite + resume works")
        } catch { print("ERROR: \(error)") }
    }
}
