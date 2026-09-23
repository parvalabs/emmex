import Foundation
import Observation
import FoundationModels
import MlexCore

/// One entry in the conversation timeline.
struct TimelineItem: Identifiable {
    enum Kind { case user, assistant, toolCall, toolResult, error }
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

    // Session
    var selected: ModelSpec = .system
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
    }

    // MARK: models

    func pull() {
        let id = pullID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, pulls[id] == nil else { return }
        pulls[id] = 0; pullErrors[id] = nil
        Task {
            do {
                _ = try await ModelStore.shared.pull(id) { fraction, _ in
                    Task { @MainActor in self.pulls[id] = fraction }
                }
                pulls[id] = nil
                await refresh()
            } catch {
                pulls[id] = nil
                pullErrors[id] = "\(error)"
            }
        }
    }

    func remove(_ id: String) {
        Task { try? await ModelStore.shared.remove(id); await refresh() }
    }

    // MARK: session

    /// Switching model keeps the conversation: the new session starts from the old transcript.
    func select(_ spec: ModelSpec) {
        guard spec != selected else { return }
        selected = spec
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
        do {
            agent = try await AgentSession(spec: selected, cwd: workspace.path, transcript: transcript) { [weak self] ev in
                Task { @MainActor in self?.handle(ev) }
            }
        } catch {
            timeline.append(.init(kind: .error, text: "\(error)"))
        }
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
            do { try await agent.run(prompt) }
            catch { timeline.append(.init(kind: .error, text: "\(error)")) }
            busy = false
        }
    }

    func clear() {
        timeline = []; agent = nil; lastUsage = nil
    }

    private func handle(_ ev: AgentEvent) {
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
        }
    }
}
