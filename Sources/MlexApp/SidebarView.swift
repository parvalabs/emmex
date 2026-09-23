import SwiftUI
import AppKit
import MlexCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var newWorktree = false
    @State private var branch = ""

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().overlay(Theme.hairline)
            sessionList
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
        .sheet(isPresented: $newWorktree) { worktreeSheet }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.recents) { w in
                    Button(w.name) { model.openWorkspace(w.url) }
                }
                if !model.recents.isEmpty { Divider() }
                Button("Open Folder…") { model.chooseWorkspace() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                    Text(model.workspace?.lastPathComponent ?? "Open a folder").font(Theme.body.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
            Menu {
                Button("New session") { model.newSession() }
                Button("New session in worktree…") { branch = ""; newWorktree = true }
            } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) } primaryAction: { model.newSession() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.workspace == nil)
            .help("New session")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.sessions.isEmpty {
                    Text(model.workspace == nil ? "Choose a folder to start." : "No sessions yet.")
                        .font(Theme.small).foregroundStyle(Theme.muted).padding(12)
                }
                ForEach(model.sessions) { s in
                    SessionRow(summary: s, selected: s.id == model.current?.record.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.resume(s.id) }
                        .contextMenu {
                            Button("Rename…") { model.renaming = s }
                            if let wt = s.worktree { Button("Reveal worktree \(wt)") { model.revealWorktree(s.id) } }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteSession(s.id) }
                        }
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.showModels = true } label: { Label("Models", systemImage: "cpu") }
            Button { model.showWorkspaceInfo = true } label: { Label("Tools", systemImage: "puzzlepiece.extension") }
            Spacer()
            Text(SystemMemory.format(model.footprint)).font(Theme.small).foregroundStyle(Theme.muted).monospacedDigit()
                .help("App memory · free \(SystemMemory.format(SystemMemory.available()))")
        }
        .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.muted)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var worktreeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New session in a worktree").font(.headline)
            Text("A git worktree on this branch is created outside the repo. The session's tools run there, so the main checkout stays untouched.")
                .font(Theme.small).foregroundStyle(Theme.muted)
            TextField("branch-name", text: $branch).textFieldStyle(.roundedBorder).font(Theme.mono)
            HStack { Spacer()
                Button("Cancel") { newWorktree = false }.keyboardShortcut(.cancelAction)
                Button("Create") { model.newSession(worktree: branch); newWorktree = false }
                    .keyboardShortcut(.defaultAction).disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 380)
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.title).font(Theme.body).lineLimit(1)
            HStack(spacing: 6) {
                Text(summary.model).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
                if let wt = summary.worktree {
                    Text(wt).font(Theme.small).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(summary.updatedAt.relative).font(Theme.small).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
