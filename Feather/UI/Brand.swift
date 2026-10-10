import SwiftUI

/// Feather's palette, taken from the app icon's lavender panel (#A09ADA) with a deeper shade in light mode for contrast.
/// Neutrals stay on the system materials so the window still looks native.
enum Brand {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.627, green: 0.604, blue: 0.855, alpha: 1)      // #A09ADA
            : NSColor(srgbRed: 0.478, green: 0.447, blue: 0.788, alpha: 1)      // #7A72C9
    })
}
