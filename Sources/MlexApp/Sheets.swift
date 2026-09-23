import SwiftUI
import MlexCore

struct ModelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Models").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.backends, id: \.spec) { b in
                    let spec = try? ModelSpec(parsing: b.spec)
                    HStack(spacing: 10) {
                        Circle().fill(b.available ? .green : Theme.muted.opacity(0.5)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.spec).font(Theme.mono)
                            Text(b.detail).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        Spacer()
                        if case .mlx(let id)? = spec {
                            if model.loadingID == id { ProgressView().controlSize(.small) }
                            else if model.residentID == id {
                                Button("Unload") { model.unloadResident() }.controlSize(.small)
                            }
                            Button(role: .destructive) { model.remove(id) } label: { Image(systemName: "trash") }.controlSize(.small)
                        }
                    }
                    .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                }
            }
            Divider()
            Text("Pull from Hugging Face").font(Theme.body.weight(.semibold))
            HStack {
                TextField("mlx-community/…", text: $model.pullID).textFieldStyle(.roundedBorder).font(Theme.mono).onSubmit { model.pull() }
                Button("Pull") { model.pull() }.disabled(model.pullID.isEmpty)
            }
            ForEach(model.pulls.keys.sorted(), id: \.self) { id in
                HStack {
                    Text(id).font(Theme.small).lineLimit(1)
                    ProgressView(value: model.pulls[id] ?? 0)
                    Text("\(Int((model.pulls[id] ?? 0) * 100))%").font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                    Button { model.cancelPull(id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            }
            ForEach(model.pullErrors.keys.sorted(), id: \.self) { id in
                Text("\(id): \(model.pullErrors[id] ?? "")").font(Theme.small).foregroundStyle(.red)
            }
            Text("Only one MLX model stays loaded; selecting another unloads it. Weights live in ~/.cache/mlex/models.")
                .font(Theme.small).foregroundStyle(Theme.muted)
        }
        .padding(18).frame(width: 560)
    }
}

struct WorkspaceInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(model.workspace?.lastPathComponent ?? "Workspace").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("MCP servers", hint: ".mlex/mcp.json or ~/.mlex/mcp.json") {
                        if model.mcpSummary.isEmpty && model.mcpFailures.isEmpty { Text("None configured.").font(Theme.small).foregroundStyle(Theme.muted) }
                        ForEach(model.mcpSummary, id: \.server) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) { Circle().fill(.green).frame(width: 7, height: 7); Text(s.server).font(Theme.body.weight(.semibold)); Text(s.info).font(Theme.small).foregroundStyle(Theme.muted) }
                                Text(s.tools.joined(separator: ", ")).font(Theme.small).foregroundStyle(Theme.muted)
                            }
                        }
                        ForEach(model.mcpFailures.keys.sorted(), id: \.self) { k in
                            HStack(spacing: 6) { Circle().fill(.red).frame(width: 7, height: 7); Text(k).font(Theme.body); Text(model.mcpFailures[k] ?? "").font(Theme.small).foregroundStyle(.red).lineLimit(2) }
                        }
                    }
                    section("Skills", hint: ".mlex/skills, .agents/skills, .claude/skills") {
                        if model.commands.skills.isEmpty { Text("None found.").font(Theme.small).foregroundStyle(Theme.muted) }
                        ForEach(model.commands.skills) { k in
                            VStack(alignment: .leading, spacing: 1) { Text("/skill:\(k.name)").font(Theme.mono); Text(k.description).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(2) }
                        }
                    }
                    section("Prompt templates", hint: ".mlex/prompts, .claude/commands") {
                        if model.commands.templates.isEmpty { Text("None found.").font(Theme.small).foregroundStyle(Theme.muted) }
                        ForEach(model.commands.templates) { t in
                            VStack(alignment: .leading, spacing: 1) { Text("/\(t.name) \(t.argumentHint ?? "")").font(Theme.mono); Text(t.description).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(2) }
                        }
                    }
                    section("Memory", hint: "extracted on-device after each turn") {
                        if model.memory.isEmpty { Text("Nothing remembered yet.").font(Theme.small).foregroundStyle(Theme.muted) }
                        ForEach(model.memory.sorted { $0.createdAt > $1.createdAt }) { f in
                            HStack(alignment: .top, spacing: 6) {
                                Text(f.kind).font(Theme.small).foregroundStyle(Theme.accent).frame(width: 66, alignment: .leading)
                                Text(f.text).font(Theme.small)
                                Spacer()
                                Button { model.forget(f.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                            }
                        }
                        if !model.memory.isEmpty { Button("Forget everything", role: .destructive) { model.clearMemory() }.controlSize(.small) }
                    }
                    section("Tools in this session", hint: nil) {
                        Text((model.current?.toolNames ?? []).joined(separator: ", ")).font(Theme.small).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(18).frame(width: 560, height: 520)
    }

    private func section<C: View>(_ title: String, hint: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(Theme.body.weight(.semibold)); Spacer(); if let hint { Text(hint).font(Theme.small).foregroundStyle(Theme.muted) } }
            content()
        }
    }
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary
    @State private var title: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).onAppear { title = session.title }
            HStack { Spacer(); Button("Cancel") { model.renaming = nil }.keyboardShortcut(.cancelAction); Button("Rename") { model.rename(session.id, to: title); model.renaming = nil }.keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 360)
    }
}
