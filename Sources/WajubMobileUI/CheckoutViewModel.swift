#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
import WajubMobile

/// Bridges the UI-agnostic `CheckoutController` to SwiftUI.
@MainActor
final class CheckoutViewModel: ObservableObject {
    let controller: CheckoutController
    let inherited: InheritedTheme?
    /// The scheme the sheet forces (`nil`: follow the OS).
    var onSchemePreference: ((ColorSchemeKind?) -> Void)?
    var onUpdate: (() -> Void)?
    private var reportedPreference = false
    private var lastPreference: ColorSchemeKind?

    init(controller: CheckoutController, inherited: InheritedTheme?) {
        self.controller = controller
        self.inherited = inherited
        controller.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.onUpdate?()
            self.reportSchemePreference()
        }
    }

    var strings: WajubStrings { controller.strings }

    /// The theme for the OS's current scheme (appearance.md §5).
    func theme(system: ColorScheme) -> ResolvedTheme {
        ThemeResolver.resolve(appearance: controller.options.appearance, branding: controller.session?.branding,
                              inherited: inherited, system: system == .dark ? .dark : .light)
    }

    private func reportSchemePreference() {
        let preference = ThemeResolver.schemePreference(appearance: controller.options.appearance,
                                                        branding: controller.session?.branding, inherited: inherited)
        guard !reportedPreference || lastPreference != preference else { return }
        reportedPreference = true
        lastPreference = preference
        onSchemePreference?(preference)
    }
}

/// The resolved theme, as SwiftUI values.
struct SheetStyle {
    let theme: ResolvedTheme
    let reduceMotion: Bool

    var tokens: ThemeTokens { theme.tokens }
    var radius: CGFloat { CGFloat(theme.shape.radius) }
    var unit: CGFloat { CGFloat(theme.shape.spacingUnit) }
    var gapRow: CGFloat { CGFloat(theme.shape.gapRow) }
    var gapColumn: CGFloat { CGFloat(theme.shape.gapColumn) }
    var animates: Bool { !theme.disableAnimations && !reduceMotion }

    func color(_ value: RGBAColor) -> Color {
        Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }

    var primary: Color { color(tokens.primary) }
    var onPrimary: Color { color(tokens.onPrimary) }
    var background: Color { color(tokens.background) }
    var surfaceMuted: Color { color(tokens.surfaceMuted) }
    var selected: Color { color(tokens.selectedBackground) }
    var text: Color { color(tokens.text) }
    var textSecondary: Color { color(tokens.textSecondary) }
    var textPlaceholder: Color { color(tokens.textPlaceholder) }
    var inputBackground: Color { color(tokens.inputBackground) }
    var inputBorder: Color { color(tokens.inputBorder) }
    var danger: Color { color(tokens.danger) }
    var dangerBackground: Color { color(tokens.dangerBackground) }
    var success: Color { color(tokens.success) }
    var successBackground: Color { color(tokens.successBackground) }
    var warning: Color { color(tokens.warning) }
    var warningBackground: Color { color(tokens.warningBackground) }
    var separator: Color { theme.separator.map(color) ?? color(tokens.inputBorder) }

    /// The first family of the stack the app ships, else the platform's font.
    func font(size: Double, weight: Int) -> Font {
        let scaled = UIFontMetrics.default.scaledValue(for: CGFloat(size))
        for family in theme.shape.fontFamilies where UIFont(name: family, size: scaled) != nil {
            return Font.custom(family, size: scaled).weight(SheetStyle.weight(weight))
        }
        return Font.system(size: scaled, weight: SheetStyle.weight(weight))
    }

    var body: Font { font(size: theme.shape.fontSizeBase, weight: theme.shape.fontWeightNormal) }
    var input: Font { font(size: theme.shape.fontSizeInput, weight: theme.shape.fontWeightNormal) }
    var label: Font { font(size: theme.shape.fontSizeLabel, weight: theme.shape.fontWeightMedium) }
    var hint: Font { font(size: theme.shape.fontSizeLabel, weight: theme.shape.fontWeightNormal) }
    var title: Font { font(size: theme.shape.fontSizeBase * 1.25, weight: theme.shape.fontWeightBold) }
    var amount: Font { font(size: theme.shape.fontSizeBase * 1.75, weight: theme.shape.fontWeightBold) }
    var button: Font { font(size: theme.shape.fontSizeBase, weight: theme.shape.fontWeightBold) }

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}
#endif
