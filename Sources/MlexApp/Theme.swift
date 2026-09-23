import SwiftUI

/// Visual language: neutral surfaces, one accent, tight type, hairline borders.
enum Theme {
    static let accent = Color.accentColor
    static let sidebarWidth: CGFloat = 260

    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var sidebar: Color { Color(nsColor: .underPageBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }
    static var muted: Color { .secondary }

    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let radius: CGFloat = 8
}

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline, lineWidth: 0.5))
    }
}

/// Pill-shaped control used in the top bar.
struct Pill<Label: View>: View {
    @ViewBuilder var label: Label
    var body: some View {
        label
            .font(Theme.small.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: Date())
    }
}
