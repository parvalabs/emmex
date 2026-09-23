import Foundation
import FoundationModels

/// One agent conversation on one model, with tools, streaming events, and a persistable transcript.
public final class AgentSession: @unchecked Sendable {
    public let spec: ModelSpec
    public let cwd: String
    public private(set) var session: LanguageModelSession
    private let sink: EventSink

    public static let defaultInstructions = """
    You are mlex, a coding agent working in the user's project directory. Tools let you inspect \
    and change files and run commands. Use a tool only when the request needs information from \
    the project or asks for a change or a command; for conversation, questions you can answer \
    directly, or instructions like "say X", reply in text without tools. Run one command per tool \
    call and read its output before deciding the next step. Never use interactive commands. Be \
    terse and concrete.
    """

    public init(spec: ModelSpec, cwd: String, instructions: String? = nil,
                transcript: Transcript? = nil, sink: @escaping EventSink) async throws {
        self.spec = spec; self.cwd = cwd; self.sink = sink
        let ctx = ToolContext(cwd: cwd, report: sink)
        self.session = try await Backends.makeSession(
            spec, tools: Tools.standard(ctx),
            instructions: instructions ?? Self.defaultInstructions, transcript: transcript,
            onWarning: { sink(.warning($0)) })
    }

    public var transcript: Transcript { session.transcript }

    /// Run one user turn, streaming text deltas and tool events to the sink. Returns the final text.
    @discardableResult
    public func run(_ prompt: String, effort: Effort = .default) async throws -> String {
        var last = ""
        let stream = session.streamResponse(to: prompt, contextOptions: effort.contextOptions(for: spec))
        var usage: LanguageModelSession.Usage? = nil
        for try await snapshot in stream {
            let full = snapshot.content
            if full.count > last.count, full.hasPrefix(last) {
                sink(.textDelta(String(full.dropFirst(last.count))))
            } else if full != last {
                sink(.textDelta(full))
            }
            last = full
            usage = snapshot.usage
        }
        sink(.finished(usage: usage, text: last))
        return last
    }

    // MARK: persistence

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(session.transcript)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func loadTranscript(from url: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }
}
