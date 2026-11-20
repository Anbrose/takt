import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colour tokens from the design (`.t-light` / `.t-dark` in prototype/*.dc.html).
/// `accent` is for graphics only (routes, selected borders, progress); text and filled
/// buttons use `accentText` / `fill`, which meet 4.5:1.
public enum Palette {
    public static let bg = Color(light: 0xFAF7F8, dark: 0x1A1A1D)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x25252A)
    public static let text = Color(light: 0x1A1A1D, dark: 0xF4F1F3)
    public static let muted = Color(light: 0x5F5660, dark: 0xB4ADB3)
    public static let line = Color(light: 0xEAD8E0, dark: 0x3A3A41)
    public static let accent = Color(light: 0xE6397C, dark: 0xE6397C)
    public static let accentText = Color(light: 0xC2185B, dark: 0xFF8AB5)
    public static let fill = Color(light: 0xC2185B, dark: 0xF272A3)
    public static let onFill = Color(light: 0xFFFFFF, dark: 0x1A1A1D)
    /// 删除 (swipe action) — white text on it passes 4.5:1 in both themes.
    public static let danger = Color(light: 0xC62828, dark: 0xC62828)
    public static let soft = Color(light: 0xFCE6EF, dark: 0x3A2230)
    public static let map = Color(light: 0xF7ECF1, dark: 0x202024)
    public static let grid = Color(light: 0xEBD8E0, dark: 0x2E2E34)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Timings from the prototype. All of them collapse to nil under 减少动态效果.
public enum Motion {
    /// Neighbours making room while dragging.
    public static let makeRoom = Animation.easeInOut(duration: 0.18)
    /// Rows settling into a new order (drop, 取消, 重排) — the FLIP equivalent.
    public static let settle = Animation.easeInOut(duration: 0.24)
    /// Bottom bar / sheet sliding in or out.
    public static let sheet = Animation.easeInOut(duration: 0.3)
    /// Level navigation, segmented highlights, rail.
    public static let nav = Animation.easeOut(duration: 0.28)
    /// Colour / check / border fades.
    public static let fade = Animation.easeInOut(duration: 0.28)

    static func with<R>(_ animation: Animation, reduce: Bool, _ body: () throws -> R) rethrows -> R {
        try withAnimation(reduce ? nil : animation, body)
    }
}

extension View {
    /// `.animation` that respects 减少动态效果.
    func motion<V: Equatable>(_ animation: Animation, value: V, reduce: Bool) -> some View {
        self.animation(reduce ? nil : animation, value: value)
    }
}

public enum Metrics {
    /// Minimum touch target.
    public static let hit: CGFloat = 44
    public static let gutter: CGFloat = 16
    public static let cardRadius: CGFloat = 14
    public static let controlRadius: CGFloat = 12
}
