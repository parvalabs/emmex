import SwiftUI

/// Markdown with fenced code blocks rendered as monospaced panels; everything else through
/// SwiftUI's inline markdown.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        if !lang.isEmpty {
                            Text(lang).font(Theme.small).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 10).padding(.top, 6)
                        }
                        Text(code).font(Theme.mono).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 0.5))
                case .text(let t):
                    ForEach(Array(t.split(separator: "\n\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, para in
                        Text(Self.attributed(String(para))).font(Theme.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    enum Block { case text(String), code(String, String) }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var cur = ""
        var inCode = false, lang = ""
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inCode { out.append(.code(lang, cur.trimmingCharacters(in: .newlines))); cur = ""; inCode = false }
                else { if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(cur)) }; cur = ""; inCode = true; lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            } else { cur += line + "\n" }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(inCode ? .code(lang, cur) : .text(cur)) }
        return out
    }

    static func attributed(_ s: String) -> AttributedString {
        // Bullets render better as real lines than as inline markdown.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            return (t.hasPrefix("- ") || t.hasPrefix("* ")) ? "•  " + t.dropFirst(2) : String(line)
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: lines, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
