import SwiftUI
import MlexCore

@main
struct MlexApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("mlex") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await model.refresh()
                    // Debug hook: MLEX_AUTOPROMPT="…" MLEX_WORKSPACE=/path sends a prompt on launch.
                    let env = ProcessInfo.processInfo.environment
                    if let ws = env["MLEX_WORKSPACE"] { model.setWorkspace(URL(fileURLWithPath: ws)) }
                    if let p = env["MLEX_AUTOPROMPT"] { model.input = p; model.send() }
                }
        }
        .windowStyle(.titleBar)
    }
}
