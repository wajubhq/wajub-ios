import Foundation

/// `theme`: a colour scheme (`light`, `dark`, `auto`, `system`) or one of Wajub.js's presets.
public enum AppearanceTheme: String, Sendable, CaseIterable {
    case light, dark, auto, system, stripe, night, flat, none
}

/// `colorScheme`.
public enum AppearanceColorScheme: String, Sendable, CaseIterable {
    case light, dark, auto
}

/// `shadow`: the sheet's elevation.
public enum AppearanceShadow: String, Sendable, CaseIterable {
    case none, low, high
}

/// `labels`.
public enum AppearanceLabels: String, Sendable, CaseIterable {
    case above, floating
}

/// Wajub.js's appearance variables, same names (`appearance.js:54-71`). Values are CSS-like strings:
/// colours `#rrggbb`/`rgb()`, lengths `"8px"`, `"8"`, `"0.5rem"`, weights `"600"`/`"bold"`.
public struct AppearanceVariables: Equatable, Sendable {
    public var colorPrimary: String?
    public var colorBackground: String?
    public var colorText: String?
    public var colorTextSecondary: String?
    public var colorTextPlaceholder: String?
    public var colorDanger: String?
    public var colorSuccess: String?
    public var fontFamily: String?
    public var fontSizeBase: String?
    public var fontWeightNormal: String?
    public var fontWeightMedium: String?
    public var fontWeightBold: String?
    public var spacingUnit: String?
    public var borderRadius: String?
    public var spacingGridRow: String?
    public var spacingGridColumn: String?

    public init(colorPrimary: String? = nil, colorBackground: String? = nil, colorText: String? = nil,
                colorTextSecondary: String? = nil, colorTextPlaceholder: String? = nil, colorDanger: String? = nil,
                colorSuccess: String? = nil, fontFamily: String? = nil, fontSizeBase: String? = nil,
                fontWeightNormal: String? = nil, fontWeightMedium: String? = nil, fontWeightBold: String? = nil,
                spacingUnit: String? = nil, borderRadius: String? = nil, spacingGridRow: String? = nil,
                spacingGridColumn: String? = nil) {
        self.colorPrimary = colorPrimary
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.colorTextSecondary = colorTextSecondary
        self.colorTextPlaceholder = colorTextPlaceholder
        self.colorDanger = colorDanger
        self.colorSuccess = colorSuccess
        self.fontFamily = fontFamily
        self.fontSizeBase = fontSizeBase
        self.fontWeightNormal = fontWeightNormal
        self.fontWeightMedium = fontWeightMedium
        self.fontWeightBold = fontWeightBold
        self.spacingUnit = spacingUnit
        self.borderRadius = borderRadius
        self.spacingGridRow = spacingGridRow
        self.spacingGridColumn = spacingGridColumn
    }

    /// Reads Wajub.js's `variables` object; unknown keys and non-string values are ignored.
    public init(json: JSONValue) {
        func text(_ key: String) -> String? {
            guard let value = json[key] else { return nil }
            if case .number(let number) = value { return JSONValue.format(number) }
            return value.nonEmptyString
        }
        self.init(colorPrimary: text("colorPrimary"), colorBackground: text("colorBackground"), colorText: text("colorText"),
                  colorTextSecondary: text("colorTextSecondary"), colorTextPlaceholder: text("colorTextPlaceholder"),
                  colorDanger: text("colorDanger"), colorSuccess: text("colorSuccess"), fontFamily: text("fontFamily"),
                  fontSizeBase: text("fontSizeBase"), fontWeightNormal: text("fontWeightNormal"),
                  fontWeightMedium: text("fontWeightMedium"), fontWeightBold: text("fontWeightBold"),
                  spacingUnit: text("spacingUnit"), borderRadius: text("borderRadius"), spacingGridRow: text("spacingGridRow"),
                  spacingGridColumn: text("spacingGridColumn"))
    }
}

/// `PresentOptions.appearance`: the same object as Wajub.js 1.8's `AppearanceConfig`, so the web
/// Components and the native sheet are styled alike. Values that do not parse are ignored.
public struct Appearance: Equatable, Sendable {
    public var theme: AppearanceTheme?
    public var colorScheme: AppearanceColorScheme?
    /// Take the host app's own theme (appearance.md §3).
    public var inherit: Bool?
    public var variables: AppearanceVariables
    public var primaryColor: String?
    public var secondaryColor: String?
    public var backgroundColor: String?
    public var fontFamily: String?
    public var borderRadius: String?
    public var buttonTextColor: String?
    public var inputBackgroundColor: String?
    public var inputBorderColor: String?
    public var textMutedColor: String?
    public var successColor: String?
    public var errorColor: String?
    public var shadow: AppearanceShadow?
    public var labels: AppearanceLabels?
    public var disableAnimations: Bool?

    public init(theme: AppearanceTheme? = nil, colorScheme: AppearanceColorScheme? = nil, inherit: Bool? = nil,
                variables: AppearanceVariables = AppearanceVariables(), primaryColor: String? = nil,
                secondaryColor: String? = nil, backgroundColor: String? = nil, fontFamily: String? = nil,
                borderRadius: String? = nil, buttonTextColor: String? = nil, inputBackgroundColor: String? = nil,
                inputBorderColor: String? = nil, textMutedColor: String? = nil, successColor: String? = nil,
                errorColor: String? = nil, shadow: AppearanceShadow? = nil, labels: AppearanceLabels? = nil,
                disableAnimations: Bool? = nil) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.inherit = inherit
        self.variables = variables
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.backgroundColor = backgroundColor
        self.fontFamily = fontFamily
        self.borderRadius = borderRadius
        self.buttonTextColor = buttonTextColor
        self.inputBackgroundColor = inputBackgroundColor
        self.inputBorderColor = inputBorderColor
        self.textMutedColor = textMutedColor
        self.successColor = successColor
        self.errorColor = errorColor
        self.shadow = shadow
        self.labels = labels
        self.disableAnimations = disableAnimations
    }

    /// Reads Wajub.js's appearance object (for an app that shares it with its web checkout).
    /// Unknown keys (`rules` included) and values that do not parse are ignored.
    public init(json: JSONValue) {
        func text(_ key: String) -> String? {
            guard let value = json[key] else { return nil }
            if case .number(let number) = value { return JSONValue.format(number) }
            return value.nonEmptyString
        }
        self.init(theme: text("theme").flatMap(AppearanceTheme.init(rawValue:)),
                  colorScheme: text("colorScheme").flatMap(AppearanceColorScheme.init(rawValue:)),
                  inherit: json["inherit"]?.bool,
                  variables: json["variables"].map(AppearanceVariables.init(json:)) ?? AppearanceVariables(),
                  primaryColor: text("primaryColor"), secondaryColor: text("secondaryColor"),
                  backgroundColor: text("backgroundColor"), fontFamily: text("fontFamily"), borderRadius: text("borderRadius"),
                  buttonTextColor: text("buttonTextColor"), inputBackgroundColor: text("inputBackgroundColor"),
                  inputBorderColor: text("inputBorderColor"), textMutedColor: text("textMutedColor"),
                  successColor: text("successColor"), errorColor: text("errorColor"),
                  shadow: text("shadow").flatMap(AppearanceShadow.init(rawValue:)),
                  labels: text("labels").flatMap(AppearanceLabels.init(rawValue:)),
                  disableAnimations: json["disableAnimations"]?.bool)
    }

    /// Wajub.js's presets, identical values (`appearance.js:26-47`).
    public static func preset(_ theme: AppearanceTheme) -> Appearance? {
        switch theme {
        case .stripe:
            return Appearance(primaryColor: "#0570de", fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
                              borderRadius: "4px", shadow: .low)
        case .night:
            return Appearance(colorScheme: .dark, primaryColor: "#7c3aed", backgroundColor: "#0f172a", borderRadius: "8px",
                              buttonTextColor: "#f8fafc", inputBackgroundColor: "#1e293b", inputBorderColor: "#334155",
                              textMutedColor: "#94a3b8", shadow: AppearanceShadow.none)
        case .flat:
            return Appearance(borderRadius: "0", shadow: AppearanceShadow.none)
        case .none:
            return Appearance()
        case .light, .dark, .auto, .system:
            return nil
        }
    }
}

/// How `loader` draws the wait before the first screen.
public enum LoaderStyle: String, Sendable {
    /// Placeholder blocks in the resolved theme, pulsing (default).
    case skeleton
    /// A centred activity indicator in `primary`.
    case spinner

    /// Wajub.js's `"none"` is a spinner on mobile.
    public init(wajubJS value: String) {
        self = value == "skeleton" ? .skeleton : .spinner
    }
}

/// CSS-like value parsing (appearance.md §1.2).
enum AppearanceValue {
    /// `"8px"`, `"8"` (pixels) or `"0.5rem"` (× 16). Negative or non-finite: `nil`.
    static func length(_ text: String?) -> Double? {
        guard var value = text?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        var factor = 1.0
        if value.hasSuffix("rem") {
            value.removeLast(3)
            factor = 16
        } else if value.hasSuffix("px") {
            value.removeLast(2)
        }
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite, number >= 0 else { return nil }
        return number * factor
    }

    /// `"400"`…`"700"`, `"normal"` (400), `"bold"` (700), or a number.
    static func fontWeight(_ text: String?) -> Int? {
        guard let value = text?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "normal": return 400
        case "bold": return 700
        default:
            guard let number = Double(value), number.isFinite, (1...1000).contains(number) else { return nil }
            return Int(number)
        }
    }

    /// The families of a CSS font stack to try in order, quotes removed; `nil` when no stack is given.
    /// The stack stops at its first system or generic family (`-apple-system`, `system-ui`,
    /// `sans-serif`…): from there on it is the platform's font.
    static func fontStack(_ text: String?) -> [String]? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let system: Set<String> = ["serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "-apple-system",
                                   "blinkmacsystemfont", "ui-sans-serif", "ui-serif", "ui-monospace", "ui-rounded"]
        var families: [String] = []
        for entry in text.split(separator: ",") {
            let name = entry.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if name.isEmpty { continue }
            if system.contains(name.lowercased()) { break }
            families.append(name)
        }
        return families
    }

    /// Merchant `border_radius`: `"12px"`, `"12"`, or a token `none` / `sm` / `md` / `lg` / `xl`.
    static func brandingRadius(_ text: String?) -> Double? {
        switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "none": return 0
        case "sm": return 4
        case "md": return 8
        case "lg": return 12
        case "xl": return 16
        default: return length(text)
        }
    }
}
