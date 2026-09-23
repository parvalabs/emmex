import SwiftUI
import MlexCore

@main
struct MlexApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("mlex") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    let env = ProcessInfo.processInfo.environment
                    await model.start(autoOpen: env["MLEX_WORKSPACE"] == nil)
                    if let ws = env["MLEX_WORKSPACE"] { model.openWorkspace(URL(fileURLWithPath: ws)) }
                    if let m = env["MLEX_MODEL"], let spec = try? ModelSpec(parsing: m) { model.select(spec) }
                    if let p = env["MLEX_AUTOPROMPT"] { model.input = p; model.send() }
                    if let seq = env["MLEX_AUTOSWITCH"] {
                        for s in seq.split(separator: ",") {
                            try? await Task.sleep(for: .milliseconds(300))
                            if let spec = try? ModelSpec(parsing: String(s)) { model.select(spec) }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") { model.newSession() }.keyboardShortcut("n")
                Button("Open Folder…") { model.chooseWorkspace() }.keyboardShortcut("o")
                Button("Compact Context") { model.compact() }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Export Session…") { model.exportSession() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SidebarView()
            Divider().overlay(Theme.hairline)
            ChatView()
        }
        .sheet(isPresented: $model.showModels) { ModelsSheet().environment(model) }
        .sheet(isPresented: $model.showWorkspaceInfo) { WorkspaceInfoSheet().environment(model) }
        .sheet(item: $model.renaming) { s in RenameSheet(session: s).environment(model) }
    }
}
