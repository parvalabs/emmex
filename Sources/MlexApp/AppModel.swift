import Foundation
import Observation
import FoundationModels
import MlexCore

/// One entry in the conversation timeline.
struct TimelineItem: Identifiable {
    enum Kind { case user, assistant, toolCall, toolResult, error, warning }
    let id = UUID()
    var kind: Kind
    var title: String = ""
    var text: String
}

@MainActor @Observable
final class AppModel {
    // Backends and models
    var backends: [Backends.Status] = []
    var installed: [ModelStore.Installed] = []
    var pullID: String = "mlx-community/Qwen3-4B-4bit"
    var pulls: [String: Double] = [:]          // id -> fraction
    var pullErrors: [String: String] = [:]
    private var pullTasks: [String: Task<Void, Never>] = [:]
    var residentID: String?                   // MLX model whose weights are loaded
    var loadingID: String?                    // MLX model currently loading
    var footprint: Int64 = 0                  // this process's memory

    // Session
    var selected: ModelSpec = .system
    var effort: Effort = .default
    var workspace: URL = URL(fileURLWithPath: NSHomeDirectory())
    var timeline: [TimelineItem] = []
    var input: String = ""
    var busy = false
    var lastUsage: LanguageModelSession.Usage?
    private var agent: AgentSession?

    var specs: [ModelSpec] { backends.compactMap { try? ModelSpec(parsing: $0.spec) } }

    func refresh() async {
        backends = await Backends.status()
        installed = await ModelStore.shared.installed()
        residentID = await ModelStore.shared.residentID
        footprint = SystemMemory.footprint()
    }

    func unloadResident() {
        Task { await ModelStore.shared.unloadResident(); await refresh() }
    }

    // MARK: models

    func pull() {
        let id = pullID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, pulls[id] == nil else { return }
        pulls[id] = 0; pullErrors[id] = nil
        pullTasks[id] = Task {
            do {
                _ = try await ModelStore.shared.pull(id) { fraction, _ in
                    Task { @MainActor in self.pulls[id] = fraction }
                }
                await refresh()
            } catch is CancellationError {
                // partial files stay on disk; the next pull resumes
            } catch {
                pullErrors[id] = "\(error)"
            }
            pulls[id] = nil
            pullTasks[id] = nil
        }
    }

    func cancelPull(_ id: String) {
        pullTasks[id]?.cancel()
    }

    func remove(_ id: String) {
        Task { try? await ModelStore.shared.remove(id); await refresh() }
    }

    // MARK: session

    /// Switching model keeps the conversation: the new session starts from the old transcript.
    func select(_ spec: ModelSpec) {
        guard spec != selected else { return }
        selected = spec
        rebuildKeepingTranscript()
    }

    private func rebuildKeepingTranscript() {
        let transcript = agent?.transcript
        agent = nil
        Task { await makeAgent(transcript: transcript) }
    }

    func setWorkspace(_ url: URL) {
        workspace = url
        agent = nil
        timeline = []
    }

    private func makeAgent(transcript: Transcript?) async {
        if case .mlx(let id) = selected { loadingID = id }
        do {
            agent = try await AgentSession(spec: selected, cwd: workspace.path, transcript: transcript) { [weak self] ev in
                Task { @MainActor in self?.handle(ev) }
            }
        } catch {
            timeline.append(.init(kind: .error, text: "\(error)"))
        }
        loadingID = nil
        residentID = await ModelStore.shared.residentID
        footprint = SystemMemory.footprint()
    }

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        input = ""
        timeline.append(.init(kind: .user, text: prompt))
        busy = true
        Task {
            if agent == nil { await makeAgent(transcript: nil) }
            guard let agent else { busy = false; return }
            do { try await agent.run(prompt, effort: effort) }
            catch { timeline.append(.init(kind: .error, text: "\(error)")) }
            busy = false
        }
    }

    func clear() {
        timeline = []; agent = nil; lastUsage = nil
    }

    private func handle(_ ev: AgentEvent) {
        if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil {
            let line: String = switch ev {
            case .textDelta(let t): "text: \(t)"
            case .toolCall(let n, let a): "toolCall \(n): \(a)"
            case .toolResult(let n, let o): "toolResult \(n): \(o.prefix(80))"
            case .finished(let u, let text): "finished in=\(u?.input.totalTokenCount ?? 0) out=\(u?.output.totalTokenCount ?? 0) text=\(text.prefix(80))"
            case .warning(let w): "warning: \(w)"
            case .info(let i): "info: \(i)"
            }
            FileHandle.standardError.write(Data("[mlex] \(line)\n".utf8))
        }
        switch ev {
        case .textDelta(let t):
            if let last = timeline.indices.last, timeline[last].kind == .assistant {
                timeline[last].text += t
            } else {
                timeline.append(.init(kind: .assistant, text: t))
            }
        case .toolCall(let name, let args):
            timeline.append(.init(kind: .toolCall, title: name, text: args))
        case .toolResult(let name, let output):
            timeline.append(.init(kind: .toolResult, title: name, text: output))
        case .finished(let usage, _):
            lastUsage = usage
            footprint = SystemMemory.footprint()
        case .warning(let w):
            timeline.append(.init(kind: .warning, text: w))
        case .info(let i):
            timeline.append(.init(kind: .warning, text: i))
        }
    }
}
