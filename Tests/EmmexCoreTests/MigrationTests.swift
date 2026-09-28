import Foundation
import Testing
@testable import EmmexCore

@Suite struct MigrationTests {
    let fm = FileManager.default
    func tempHome() throws -> (home: URL, support: URL) {
        let home = fm.temporaryDirectory.appending(path: "emmex-home-\(UUID().uuidString.prefix(8))")
        let support = home.appending(path: "Library/Application Support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        return (home, support)
    }
    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func chainFromMlexThroughEmlex() throws {
        // State after the first rename: real emlex folders, mlex symlinks pointing at them.
        let (home, support) = try tempHome()
        for (old, new) in [(support.appending(path: "mlex"), support.appending(path: "emlex")),
                           (home.appending(path: ".cache/mlex"), home.appending(path: ".cache/emlex")),
                           (home.appending(path: ".mlex"), home.appending(path: ".emlex"))] {
            try write(new.appending(path: "marker.txt"), "emlex")
            try fm.createSymbolicLink(at: old, withDestinationURL: new)
        }
        let moved = Paths.migrateLegacy(home: home, support: support)
        #expect(moved.count == 3)
        #expect(read(support.appending(path: "emmex/marker.txt")) == "emlex")
        // Both older paths still resolve, through the chain.
        #expect(read(support.appending(path: "emlex/marker.txt")) == "emlex")
        #expect(read(support.appending(path: "mlex/marker.txt")) == "emlex")
        #expect(read(home.appending(path: ".cache/mlex/marker.txt")) == "emlex")
        #expect(read(home.appending(path: ".mlex/marker.txt")) == "emlex")
        #expect(Paths.migrateLegacy(home: home, support: support).isEmpty)     // idempotent
    }

    @Test func straightFromMlex() throws {
        let (home, support) = try tempHome()
        try write(home.appending(path: ".mlex/settings.json"), "{}")
        let moved = Paths.migrateLegacy(home: home, support: support)
        #expect(moved.count == 1)
        #expect(read(home.appending(path: ".emmex/settings.json")) == "{}")
        #expect(read(home.appending(path: ".mlex/settings.json")) == "{}")
    }

    @Test func existingNewFolderIsNeverOverwritten() throws {
        let (home, support) = try tempHome()
        try write(home.appending(path: ".emmex/settings.json"), "new")
        try write(home.appending(path: ".emlex/settings.json"), "old")
        #expect(Paths.migrateLegacy(home: home, support: support).isEmpty)
        #expect(read(home.appending(path: ".emmex/settings.json")) == "new")
        #expect(read(home.appending(path: ".emlex/settings.json")) == "old")
    }

    @Test func projectConfigPrefersTheNewestName() throws {
        let ws = fm.temporaryDirectory.appending(path: "emmex-ws-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: ws.appending(path: ".mlex"), withIntermediateDirectories: true)
        #expect(Paths.projectConfig(ws).lastPathComponent == ".mlex")
        try fm.createDirectory(at: ws.appending(path: ".emlex"), withIntermediateDirectories: true)
        #expect(Paths.projectConfig(ws).lastPathComponent == ".emlex")
        try fm.createDirectory(at: ws.appending(path: ".emmex"), withIntermediateDirectories: true)
        #expect(Paths.projectConfig(ws).lastPathComponent == ".emmex")
    }
}
