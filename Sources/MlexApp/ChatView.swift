import SwiftUI
import MlexCore

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.hairline)
            Timeline()
            Composer()
        }
        .background(Theme.canvas)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @State private var editingTitle = false
    @State private var draft = ""

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            if editingTitle {
                TextField("Title", text: $draft, onCommit: { if let id = model.current?.record.id { model.rename(id, to: draft) }; editingTitle = false })
                    .textFieldStyle(.plain).font(Theme.body.weight(.semibold)).frame(maxWidth: 360)
            } else {
                Text(model.current?.record.title ?? "mlex").font(Theme.body.weight(.semibold)).lineLimit(1)
                    .onTapGesture(count: 2) { draft = model.current?.record.title ?? ""; editingTitle = true }
                    .help("Double-click to rename")
            }
            if let wt = model.current?.record.worktree {
                Pill { Label(wt, systemImage: "arrow.triangle.branch") }.foregroundStyle(Theme.accent)
            }
            Spacer()
            if model.contextSize > 0 {
                Pill {
                    HStack(spacing: 5) {
                        ProgressView(value: min(1, Double(model.contextUsed) / Double(model.contextSize))).frame(width: 40).controlSize(.mini)
                        Text("\(model.contextUsed.formatted()) / \(model.contextSize.formatted())").monospacedDigit()
                    }
                }
                .help("Context tokens used. Older turns are compacted automatically.")
                .onTapGesture { model.compact() }
            }
            Menu {
                ForEach(Effort.allCases, id: \.self) { e in
                    Button { model.effort = e } label: { if e == model.effort { Label(e.rawValue.capitalized, systemImage: "checkmark") } else { Text(e.rawValue.capitalized) } }
                }
            } label: { Pill { Label("Effort \(model.effort.rawValue)", systemImage: "brain") } }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                Section("Apple") { ForEach(model.specs.filter { $0 == .system || $0 == .pcc }, id: \.self) { modelButton($0) } }
                Section("Cloud") { ForEach(model.specs.filter { if case .claude = $0 { true } else { false } }, id: \.self) { modelButton($0) } }
                Section("Local MLX") { ForEach(model.specs.filter { if case .mlx = $0 { true } else { false } }, id: \.self) { modelButton($0) } }
                Divider()
                Button("Manage models…") { model.showModels = true }
            } label: {
                Pill {
                    HStack(spacing: 5) {
                        if model.loadingID != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "cpu") }
                        Text(model.selected.description).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func modelButton(_ spec: ModelSpec) -> some View {
        Button { model.select(spec) } label: {
            if spec == model.selected { Label(spec.description, systemImage: "checkmark") } else { Text(spec.description) }
        }
    }
}

struct Timeline: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.timeline.isEmpty { EmptyState() }
                    ForEach(model.timeline) { item in TimelineRow(item: item).id(item.id) }
                    if model.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working…").font(Theme.small).foregroundStyle(Theme.muted) }.padding(.leading, 4) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.timeline.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.timeline.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct EmptyState: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.workspace?.lastPathComponent ?? "mlex").font(.system(size: 22, weight: .semibold))
            Text("Local-first agent. Ask for changes, run commands, or type / for skills and templates.")
                .font(Theme.body).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Pill { Text("\(model.current?.toolNames.count ?? 0) tools") }
                Pill { Text("\(model.commands.skills.count) skills") }
                Pill { Text("\(model.mcpSummary.count) MCP servers") }
            }.foregroundStyle(Theme.muted).padding(.top, 4)
        }
        .padding(.top, 40)
    }
}

struct TimelineRow: View {
    let item: TimelineItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 80)
                Text(item.text).font(Theme.body).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            MarkdownView(text: item.text).padding(.trailing, 40)
        case .toolCall:
            Card(padding: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "terminal").font(Theme.small).foregroundStyle(Theme.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(Theme.small.weight(.semibold))
                        Text(item.text).font(Theme.mono).foregroundStyle(Theme.muted).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                    }
                    Spacer()
                }
            }
            .onTapGesture { expanded.toggle() }
        case .toolResult:
            let first = item.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let lines = item.text.split(separator: "\n").count
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(first.isEmpty ? "(empty)" : first).font(Theme.mono).lineLimit(1)
                    if lines > 1 { Text("\(lines) lines").font(Theme.small) }
                }
                .foregroundStyle(Theme.muted).contentShape(Rectangle()).onTapGesture { expanded.toggle() }
                if expanded {
                    Text(item.text).font(Theme.mono).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 0.5))
                }
            }
            .padding(.leading, 26)
        case .info:
            Label(item.text, systemImage: "info.circle").font(Theme.small).foregroundStyle(Theme.muted)
        case .warning:
            Label(item.text, systemImage: "exclamationmark.triangle").font(Theme.small).foregroundStyle(.orange)
        case .error:
            Label(item.text, systemImage: "xmark.octagon").font(Theme.small).foregroundStyle(.red)
        }
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            let suggestions = model.slashSuggestions
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.command) { s in
                        Button {
                            model.input = s.command + " "
                        } label: {
                            HStack { Text(s.command).font(Theme.mono); Text(s.hint).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1); Spacer() }
                                .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 0.5))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.current == nil ? "Choose a folder to start" : "Ask \(model.selected.description)…  (⌘↩ to send, / for commands)",
                          text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.body).lineLimit(1...10).focused($focused)
                    .onSubmit { if !NSEvent.modifierFlags.contains(.shift) { model.send() } }
                Button { model.send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(model.input.isEmpty || model.busy ? Theme.muted.opacity(0.3) : Theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(model.busy || model.input.isEmpty || model.current == nil)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1 : 0.5))
        }
        .padding(.horizontal, 22).padding(.bottom, 14).padding(.top, 6)
        .frame(maxWidth: 864)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
    }
}
