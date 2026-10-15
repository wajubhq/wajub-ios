import Foundation

/// A colour, read from the CSS forms the appearance accepts: `#rgb`, `#rrggbb`, `#rrggbbaa`,
/// `rgb(r, g, b)` and `rgba(r, g, b, a)`, case-insensitive. Anything else does not parse.
public struct RGBAColor: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// 0…1.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `nil` for anything that is not one of the accepted forms.
    public init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let hex = Array(text.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func component(_ characters: ArraySlice<Character>) -> Double {
                Double(Int(String(characters), radix: 16) ?? 0) / 255
            }
            switch hex.count {
            case 3:
                self.init(red: component([hex[0], hex[0]]), green: component([hex[1], hex[1]]), blue: component([hex[2], hex[2]]))
            case 6:
                self.init(red: component(hex[0..<2]), green: component(hex[2..<4]), blue: component(hex[4..<6]))
            case 8:
                self.init(red: component(hex[0..<2]), green: component(hex[2..<4]), blue: component(hex[4..<6]),
                          alpha: component(hex[6..<8]))
            default:
                return nil
            }
            return
        }
        let isRGBA = text.hasPrefix("rgba(")
        guard (isRGBA || text.hasPrefix("rgb(")), text.hasSuffix(")") else { return nil }
        let inner = text.dropFirst(isRGBA ? 5 : 4).dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (isRGBA ? 4 : 3) else { return nil }
        let channels = parts.prefix(3).compactMap { Double($0) }
        guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else { return nil }
        var alpha = 1.0
        if isRGBA {
            guard let value = Double(parts[3]), (0...1).contains(value) else { return nil }
            alpha = value
        }
        self.init(red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, alpha: alpha)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        func byte(_ value: Double) -> String {
            let text = String(Int((max(0, min(1, value)) * 255).rounded()), radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    public var description: String { hex }

    /// WCAG relative luminance.
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1…21.
    public func contrast(with other: RGBAColor) -> Double {
        let first = relativeLuminance, second = other.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// `self` mixed with `other`: `amount` 0 is `self`, 1 is `other`.
    func mixed(with other: RGBAColor, amount: Double) -> RGBAColor {
        RGBAColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                  blue: blue + (other.blue - blue) * amount, alpha: alpha + (other.alpha - alpha) * amount)
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let nearBlack = RGBAColor(css: "#0A0A0A")!
}
