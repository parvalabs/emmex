import Foundation
import FoundationModels
import Testing
@testable import EmmexCore

@Suite struct NetworkPolicyTests {
    @Test func domainMatching() {
        #expect(NetworkProxy.matches(host: "github.com", allowed: ["github.com"]))
        #expect(!NetworkProxy.matches(host: "api.github.com", allowed: ["github.com"]))
        #expect(NetworkProxy.matches(host: "api.github.com", allowed: ["*.github.com"]))
        #expect(NetworkProxy.matches(host: "GitHub.com", allowed: ["*.github.com"]))
        #expect(NetworkProxy.matches(host: "evil.example", allowed: ["*"]))
        #expect(!NetworkProxy.matches(host: "notgithub.com", allowed: ["*.github.com"]))
    }
}

@Suite struct FrontmatterTests {
    @Test func splitsFieldsAndBody() {
        let (fields, body) = Frontmatter.split("---\nname: csv-summary\ndescription: \"Summarize a CSV\"\n---\nRead the file.\n")
        #expect(fields["name"] == "csv-summary")
        #expect(fields["description"] == "Summarize a CSV")
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "Read the file.")
    }
    @Test func noFrontmatterIsPassedThrough() {
        let (fields, body) = Frontmatter.split("just text")
        #expect(fields.isEmpty && body == "just text")
    }
}

@Suite struct AnnouncedActionTests {
    @Test func narratedToolUseIsDetected() {
        #expect(AgentSession.announcesAction("I'll perform a review.\n\n1. Permissions\n\nLet me examine the files:"))
        #expect(AgentSession.announcesAction("I'll run the tests now."))
    }
    @Test func answersAndQuestionsAreNot() {
        #expect(!AgentSession.announcesAction("There are 5 files in the directory."))
        #expect(!AgentSession.announcesAction("Let me know if you want me to dig deeper?"))
        #expect(!AgentSession.announcesAction(""))
    }
}

@Suite struct CompactionTests {
    func prompt(_ t: String) -> Transcript.Entry { .prompt(.init(segments: [.text(.init(content: t))])) }
    func response(_ t: String) -> Transcript.Entry { .response(.init(assetIDs: [], segments: [.text(.init(content: t))])) }
    func call() -> Transcript.Entry { .toolCalls(.init([.init(id: "c1", toolName: "bash", arguments: GeneratedContent(properties: ["command": "ls"]))])) }
    func output() -> Transcript.Entry { .toolOutput(.init(id: "c1", toolName: "bash", segments: [.text(.init(content: "exit=0"))])) }

    @Test func orphanToolOutputIsDropped() {
        let t = Transcript(entries: [prompt("hi"), output(), response("ok")])
        #expect(Compactor.sanitized(t).count == 2)
    }
    @Test func pairedToolOutputIsKept() {
        let t = Transcript(entries: [prompt("hi"), call(), output(), response("ok")])
        #expect(Compactor.sanitized(t).count == 4)
    }
    @Test func leadingResponseWithoutPromptIsDropped() {
        let t = Transcript(entries: [response("stale"), prompt("hi"), response("ok")])
        #expect(Compactor.sanitized(t).count == 2)
    }
}

@Suite struct SandboxProfileTests {
    @Test func profileDeniesByDefaultAndOpensTheWorkspace() {
        let ws = URL(fileURLWithPath: "/private/tmp/emmex-profile-test")
        let p = Sandbox(workspace: ws, cwd: ws, tempDir: ws.appending(path: "tmp"), proxyPort: nil).profile
        #expect(p.contains("(deny default)"))
        #expect(p.contains("/private/tmp/emmex-profile-test"))
        #expect(p.contains(".git"))
        #expect(!p.contains("network-outbound") || p.contains("(deny network"))
    }
    @Test func proxyPortOpensOnlyLoopback() {
        let ws = URL(fileURLWithPath: "/private/tmp/emmex-profile-test")
        let p = Sandbox(workspace: ws, cwd: ws, tempDir: ws.appending(path: "tmp"), proxyPort: 4321).profile
        #expect(p.contains("4321"))
    }
}

@Suite struct ClaudeCatalogTests {
    @Test func namesAliasesAndIdsResolveToTheSameModel() {
        #expect(ClaudeCatalog.model("opus5_5").id == "claude-opus-5-5")
        #expect(ClaudeCatalog.model("opus").id == "claude-opus-5-5")
        #expect(ClaudeCatalog.model("claude-opus-5-5").id == "claude-opus-5-5")
        #expect(ClaudeCatalog.model("haiku").id == "claude-haiku-4-5-20251001")
    }
    @Test func unknownIdsPassThrough() {
        #expect(ClaudeCatalog.model("claude-future-9").id == "claude-future-9")
    }
    @Test func pickerAddsSettingsWithoutDuplicates() {
        var s = Settings(); s.claudeModels = ["opus4_8", "claude-opus-5-5", "claude-custom-1"]
        let names = ClaudeCatalog.pickerNames(settings: s)
        #expect(names.prefix(3) == ["opus5_5", "sonnet5", "haiku"])
        #expect(!names.contains("fable5_1"))
        #expect(names.contains("opus4_8") && names.contains("claude-custom-1"))
        #expect(names.filter { $0 == "opus5_5" }.count == 1)
    }
}
