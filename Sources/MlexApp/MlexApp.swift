import SwiftUI
import AppKit
import WebKit
import MlexCore
import MlexServer

/// The Mac app is a thin native shell: a window hosting the web UI served from localhost by
/// the same server the `mlex serve` command runs. Native menus map to web actions.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil { FileHandle.standardError.write(Data("[mlex] app launched\n".utf8)) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MlexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var host = WebHost()

    var body: some Scene {
        WindowGroup("mlex") {
            WebView(url: host.url)
                .frame(minWidth: 960, minHeight: 620)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") { host.action(["type": "new_session"]) }.keyboardShortcut("n")
                Button("Open Folder…") { host.action(["type": "choose_workspace"]) }.keyboardShortcut("o")
                Button("Compact Context") { host.action(["type": "compact"]) }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Export Session…") { host.exportSession() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Open in Browser") { if let u = host.app?.url { NSWorkspace.shared.open(u) } }
            }
        }
    }
}

@MainActor @Observable
final class WebHost {
    var app: WebApp?
    var url: URL?
    private let controller = AppController()

    init() { Task { @MainActor in await self.start() } }

    private func log(_ s: String) { if ProcessInfo.processInfo.environment["MLEX_DEBUG"] != nil { FileHandle.standardError.write(Data("[mlex] \(s)\n".utf8)) } }

    func start() async {
        guard app == nil else { return }
        log("start")
        do {
            controller.canUseNativePanels = true
            let env = ProcessInfo.processInfo.environment
            let port = UInt16(env["MLEX_PORT"] ?? "") ?? 0
            let web = try WebApp(port: port, webRoot: env["MLEX_WEB_ROOT"].map { URL(fileURLWithPath: $0) }, controller: controller)
            log("listening…")
            try await web.start()
            log("server ready on \(web.url)")
            app = web; url = web.url
            await controller.start(autoOpen: env["MLEX_WORKSPACE"] == nil)
            if let ws = env["MLEX_WORKSPACE"] { controller.openWorkspace(URL(fileURLWithPath: ws)) }
            if let p = env["MLEX_AUTOPROMPT"] { controller.send(p) }
            if env["MLEX_DEBUG"] != nil { FileHandle.standardError.write(Data("[mlex] web ui at \(web.url)\n".utf8)) }
        } catch {
            FileHandle.standardError.write(Data("[mlex] web server failed: \(error)\n".utf8))
            NSAlert(error: error).runModal()
        }
    }

    func action(_ a: [String: Any]) { Task { _ = await controller.handle(a) } }

    func exportSession() {
        Task {
            let r = await controller.handle(["type": "export"])
            guard let html = r["html"] as? String else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = ((r["title"] as? String) ?? "session").prefix(40).replacingOccurrences(of: "/", with: "-") + ".html"
            panel.allowedContentTypes = [.html]
            if panel.runModal() == .OK, let u = panel.url { try? html.write(to: u, atomically: true, encoding: .utf8) }
        }
    }
}

struct WebView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true                       // Inspect Element / Safari Web Inspector
        view.underPageBackgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if let url, view.url == nil { view.load(URLRequest(url: url)) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {}
}
