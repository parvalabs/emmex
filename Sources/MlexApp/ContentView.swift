import SwiftUI
import AppKit
import MlexCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ChatView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("Workspace") {
                HStack {
                    Image(systemName: "folder")
                    Text(model.workspace.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Choose…") { chooseFolder() }.controlSize(.small)
                }
            }
            Section("Models") {
                ForEach(model.backends, id: \.spec) { b in
                    let spec = try? ModelSpec(parsing: b.spec)
                    HStack {
                        Circle().fill(b.available ? .green : .secondary).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.spec).font(.body.monospaced()).lineLimit(1)
                            Text(b.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if spec == model.selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if b.available, let spec { model.select(spec) } }
                    .contextMenu {
                        if case .mlx(let id)? = spec { Button("Remove", role: .destructive) { model.remove(id) } }
                    }
                }
            }
            Section("Pull from Hugging Face") {
                TextField("org/model", text: $model.pullID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.pull() }
                Button("Pull") { model.pull() }.disabled(model.pullID.isEmpty)
                ForEach(model.pulls.keys.sorted(), id: \.self) { id in
                    VStack(alignment: .leading) {
                        Text(id).font(.caption).lineLimit(1)
                        HStack {
                            ProgressView(value: model.pulls[id] ?? 0)
                            Text("\(Int((model.pulls[id] ?? 0) * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button { model.cancelPull(id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                        }
                    }
                }
                ForEach(model.pullErrors.keys.sorted(), id: \.self) { id in
                    Text("\(id): \(model.pullErrors[id] ?? "")").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = model.workspace
        if panel.runModal() == .OK, let url = panel.url { model.setWorkspace(url) }
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.timeline) { item in
                            TimelineRow(item: item).id(item.id)
                        }
                        if model.busy { ProgressView().controlSize(.small).padding(.leading, 12) }
                    }
                    .padding()
                }
                .onChange(of: model.timeline.count) { _, _ in
                    if let last = model.timeline.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message \(model.selected.description)…", text: $model.input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .onSubmit { model.send() }
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(model.busy || model.input.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
        .navigationTitle(model.selected.description)
        .navigationSubtitle(model.workspace.path)
        .toolbar {
            Picker("Effort", selection: $model.effort) {
                ForEach(Effort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.menu).controlSize(.small)
            .help("Reasoning effort per message: Claude effort level, thinking on/off for MLX models")
            if let u = model.lastUsage {
                Text("in \(u.input.totalTokenCount) · cached \(u.input.cachedTokenCount) · out \(u.output.totalTokenCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Clear") { model.clear() }.disabled(model.timeline.isEmpty)
        }
    }
}

struct TimelineRow: View {
    let item: TimelineItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer()
                Text(item.text).padding(10).background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            Text(LocalizedStringKey(item.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .toolCall:
            Label { Text("\(item.title): ").bold() + Text(item.text).font(.body.monospaced()) } icon: { Image(systemName: "gearshape") }
                .foregroundStyle(.secondary).lineLimit(3)
        case .toolResult:
            DisclosureGroup(isExpanded: $expanded) {
                Text(item.text).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Text(item.text.split(separator: "\n").first.map(String.init) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}
