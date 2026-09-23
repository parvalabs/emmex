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
                    if let m = env["MLEX_MODEL"], let spec = try? ModelSpec(parsing: m) { model.select(spec) }
                    // Stress hook: MLEX_AUTOSWITCH="spec1,spec2,…" selects each in turn, 300 ms apart.
                    if let seq = env["MLEX_AUTOSWITCH"] {
                        for s in seq.split(separator: ",") {
                            try? await Task.sleep(for: .milliseconds(300))
                            if let spec = try? ModelSpec(parsing: String(s)) { model.select(spec) }
                        }
                    }
                    if let p = env["MLEX_AUTOPROMPT"] { model.input = p; model.send() }
                }
        }
        .windowStyle(.titleBar)
    }
}
