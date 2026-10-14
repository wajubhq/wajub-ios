#if os(iOS)
import SwiftUI
import UIKit
import WajubMobile

/// The Pay button: `primary` background, busy spinner.
@MainActor
struct PrimaryButton: View {
    let title: String
    let style: SheetStyle
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(style.button)
                    .opacity(busy ? 0 : 1)
                if busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(style.onPrimary)
                }
            }
            .foregroundColor(style.onPrimary)
            .frame(maxWidth: .infinity, minHeight: ThemeShape.inputHeight)
            .background(RoundedRectangle(cornerRadius: style.radius).fill(style.primary))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .accessibilityLabel(Text(title))
    }
}

/// A text button in `primary` (links, "Back", "Cancel payment").
@MainActor
struct LinkButton: View {
    let title: String
    let style: SheetStyle
    var color: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(style.label)
                .foregroundColor(color ?? style.primary)
                .frame(minHeight: ThemeShape.inputHeight)
        }
        .buttonStyle(.plain)
    }
}

/// A labelled input box with its error under it.
@MainActor
struct FieldBox<Content: View>: View {
    let label: String?
    let error: String?
    let style: SheetStyle
    let content: Content

    init(label: String?, error: String?, style: SheetStyle, @ViewBuilder content: () -> Content) {
        self.label = label
        self.error = error
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.unit * 1.5) {
            if let label {
                Text(label)
                    .font(style.label)
                    .foregroundColor(style.textSecondary)
            }
            content
                .padding(.horizontal, style.unit * 3)
                .frame(minHeight: ThemeShape.inputHeight)
                .background(RoundedRectangle(cornerRadius: style.radius).fill(style.inputBackground))
                .overlay(RoundedRectangle(cornerRadius: style.radius)
                    .strokeBorder(error == nil ? style.inputBorder : style.danger, lineWidth: 1))
            if let error {
                Text(error)
                    .font(style.hint)
                    .foregroundColor(style.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A text input in the sheet's style.
@MainActor
struct InputField: View {
    let label: String
    @Binding var text: String
    let error: String?
    let style: SheetStyle
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var secure = false

    var body: some View {
        FieldBox(label: label, error: error, style: style) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(style.input)
            .foregroundColor(style.text)
            .keyboardType(keyboard)
            // A CVV or a PIN is not a password to save in the keychain.
            .textContentType(contentType ?? (secure ? .oneTimeCode : nil))
            .disableAutocorrection(true)
            .autocapitalization(keyboard == .emailAddress ? .none : .words)
        }
    }
}

/// An operator's round fallback badge (`brand_fallback`).
@MainActor
struct BrandBadge: View {
    let badge: OperatorBadge
    let size: CGFloat

    var body: some View {
        let background = RGBAColor(css: badge.background) ?? RGBAColor(red: 0.32, green: 0.32, blue: 0.32)
        let foreground = RGBAColor(css: badge.color) ?? RGBAColor(red: 1, green: 1, blue: 1)
        ZStack {
            Circle().fill(Color(.sRGB, red: background.red, green: background.green, blue: background.blue, opacity: 1))
            Text(badge.text)
                .font(.system(size: size * 0.28, weight: .bold))
                .foregroundColor(Color(.sRGB, red: foreground.red, green: foreground.green, blue: foreground.blue, opacity: 1))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An operator's logo: the `https` image when it loads, else its badge.
@MainActor
struct OperatorLogo: View {
    let choice: OperatorChoice
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url = choice.logoURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        BrandBadge(badge: choice.badge, size: size)
                    }
                }
            } else {
                BrandBadge(badge: choice.badge, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A method's logo, else a symbol for its family.
@MainActor
struct MethodLogo: View {
    let method: CheckoutMethod
    let style: SheetStyle
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url = method.logo.flatMap(URL.init(string:)), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        symbol
                    }
                }
            } else {
                symbol
            }
        }
        .frame(width: size, height: size)
    }

    private var symbol: some View {
        Image(systemName: MethodLogo.symbolName(method.kind))
            .font(.system(size: size * 0.55))
            .foregroundColor(style.textSecondary)
    }

    static func symbolName(_ kind: CheckoutMethod.Kind) -> String {
        switch kind {
        case .mobileMoney: return "iphone"
        case .card: return "creditcard"
        case .wallet: return "wallet.pass"
        }
    }
}

/// The skeleton loader: placeholder blocks in the theme, pulsing unless animations are off.
@MainActor
struct SkeletonView: View {
    let style: SheetStyle
    let label: String
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: style.gapRow) {
            block(width: 140, height: 16)
            block(height: ThemeShape.inputHeight)
            block(height: ThemeShape.inputHeight)
            block(width: 180, height: 16)
            block(height: ThemeShape.inputHeight)
            block(height: ThemeShape.inputHeight)
        }
        .opacity(dimmed ? 0.45 : 1)
        .onAppear {
            guard style.animates else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
    }

    private func block(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: style.radius)
            .fill(height > 20 ? style.inputBackground : style.surfaceMuted)
            .overlay(RoundedRectangle(cornerRadius: style.radius).strokeBorder(style.inputBorder, lineWidth: height > 20 ? 1 : 0))
            .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
    }
}

/// Seconds left until `date`, refreshed every second.
@MainActor
struct Countdown<Content: View>: View {
    let until: Date
    let content: (Int) -> Content

    init(until: Date, @ViewBuilder content: @escaping (Int) -> Content) {
        self.until = until
        self.content = content
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            content(max(0, Int(until.timeIntervalSince(context.date).rounded(.up))))
        }
    }
}

/// A form-level message (error or warning).
@MainActor
struct BannerView: View {
    let message: String
    let foreground: Color
    let background: Color
    let style: SheetStyle

    var body: some View {
        Text(message)
            .font(style.hint)
            .foregroundColor(foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(style.unit * 3)
            .background(RoundedRectangle(cornerRadius: style.radius).fill(background))
    }
}

/// The icon, title and message of an outcome screen.
@MainActor
struct OutcomeHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String?
    let style: SheetStyle

    var body: some View {
        VStack(spacing: style.unit * 3) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(style.title)
                .foregroundColor(style.text)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(style.body)
                    .foregroundColor(style.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, style.unit * 4)
    }
}
#endif
