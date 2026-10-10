import SwiftUI

/// Motion and small reusable pieces. Every animation here is triggered by a state change (a click, hover, drag, tab
/// change); nothing loops in the background, so an idle window costs no CPU. All of it is skipped when macOS
/// "Reduce motion" is on.
enum Theme {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)     // layout, selection, appear/disappear
    static let quick = Animation.spring(response: 0.22, dampingFraction: 0.86)      // hover, press
    static let fade = Animation.easeOut(duration: 0.16)

    static func animation(_ a: Animation) -> Animation? { reduceMotion ? nil : a }
    static func animate(_ a: Animation = Theme.spring, _ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(a, body) }
    }

    /// Tab rows slide down into place and shrink away.
    static let rowTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))

    /// Tile colors that sit well beside the lavender brand color.
    static let palette: [Color] = [
        Color(red: 0.64, green: 0.60, blue: 0.95),   // lavender (the brand color)
        Color(red: 0.45, green: 0.65, blue: 0.97),   // periwinkle
        Color(red: 0.33, green: 0.80, blue: 0.78),   // teal
        Color(red: 0.95, green: 0.55, blue: 0.74),   // rose
        Color(red: 0.55, green: 0.84, blue: 0.60),   // mint
        Color(red: 0.97, green: 0.70, blue: 0.55),   // peach
    ]

    /// A stable color for a site, hashed from the host (used where there is no list position, e.g. recent-site dots).
    static func tileColor(for host: String) -> Color {
        var h: UInt32 = 2166136261
        for b in host.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }
}

extension View {
    /// `.animation(_, value:)` that switches itself off for Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation = Theme.spring, value: V) -> some View {
        self.animation(Theme.animation(animation), value: value)
    }
}

/// Gentle shrink while pressed.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.animation(Theme.quick), value: configuration.isPressed)
    }
}

/// Fades a rounded highlight in behind a view while the pointer is over it.
struct HoverFill: ViewModifier {
    var radius: CGFloat = 8
    var strength = 0.08
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(hovering ? strength : 0)))
            .onHover { hovering = $0 }
            .motion(Theme.fade, value: hovering)
    }
}
extension View { func hoverFill(radius: CGFloat = 8, strength: Double = 0.08) -> some View { modifier(HoverFill(radius: radius, strength: strength)) } }

/// Fades and lifts a view into place when it first appears; `delay` staggers a group.
struct Reveal: ViewModifier {
    var delay = 0.0
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .scaleEffect(shown ? 1 : 0.97)
            .onAppear {
                if Theme.reduceMotion { shown = true } else { withAnimation(Theme.spring.delay(delay)) { shown = true } }
            }
    }
}
extension View { func reveal(delay: Double = 0) -> some View { modifier(Reveal(delay: delay)) } }

/// Toolbar-style icon button: hover highlight, press shrink, symbol cross-fade when the icon changes,
/// and (for reload) a quick spin when clicked.
struct IconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    var spins = false
    let action: () -> Void
    @State private var hovering = false
    @State private var angle = 0.0

    var body: some View {
        Button {
            if spins && !Theme.reduceMotion { withAnimation(.easeInOut(duration: 0.55)) { angle += 360 } }
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(angle))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering && enabled ? 0.10 : 0)))
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(Color.primary.opacity(enabled ? (hovering ? 0.95 : 0.6) : 0.22))
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .motion(Theme.fade, value: hovering)
        .help(help)
    }
}
