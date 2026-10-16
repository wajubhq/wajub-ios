#if os(iOS)
import SwiftUI
import UIKit
import WajubMobile

/// The code the payer generates in their operator's menu (`PAYER_OTP_REQUIRED`): the steps, the code to
/// dial (to copy: iOS cannot dial `*` and `#` from a link), the exact amount, and the code field.
@MainActor
struct PayerOTPView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let screen: PayerOTPScreen
    @State private var code = ""
    @State private var copied = false

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(alignment: .leading, spacing: style.gapRow) {
            Text(strings.payerOTPTitle)
                .font(style.title)
                .foregroundColor(style.text)
            Text(strings.payerOTPDescription)
                .font(style.hint)
                .foregroundColor(style.textSecondary)
            if let ussdCode = screen.instructions.ussdCode {
                FieldBox(label: strings.payerOTPDial, error: nil, style: style) {
                    HStack {
                        Text(ussdCode)
                            .font(style.input)
                            .foregroundColor(style.text)
                            .textSelection(.enabled)
                        Spacer()
                        LinkButton(title: copied ? strings.copied : strings.copy, style: style) {
                            UIPasteboard.general.string = ussdCode
                            copied = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                copied = false
                            }
                        }
                    }
                }
            }
            if let exactAmount = screen.exactAmount {
                FieldBox(label: strings.payerOTPAmount, error: nil, style: style) {
                    Text(exactAmount)
                        .font(style.input)
                        .foregroundColor(style.text)
                        .textSelection(.enabled)
                }
            }
            Text(strings.payerOTPStepsTitle)
                .font(style.label)
                .foregroundColor(style.text)
            ForEach(Array(screen.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: style.unit * 2) {
                    Text("\(index + 1).")
                        .font(style.body)
                        .foregroundColor(style.textSecondary)
                    PayerOTPView.text(step, style: style)
                        .font(style.body)
                        .foregroundColor(style.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let sandboxCode = screen.sandboxCode {
                BannerView(message: strings.payerOTPSandboxHint(sandboxCode), foreground: style.warning,
                           background: style.warningBackground, style: style)
            }
            if let length = screen.instructions.otpLength, length <= 8 {
                CodeBoxes(label: strings.payerOTPCodeLabel, code: $code, length: length, style: style)
            } else {
                InputField(label: strings.payerOTPCodeLabel, text: $code, error: nil, style: style, keyboard: .numberPad,
                           contentType: .oneTimeCode)
            }
            if let message = screen.message {
                let attempts = screen.attemptsRemaining.map { " " + strings.payerOTPAttemptsRemaining($0) } ?? ""
                BannerView(message: message + attempts, foreground: style.danger, background: style.dangerBackground, style: style)
            }
            PrimaryButton(title: strings.payerOTPSubmit, style: style, busy: controller.isPaying, enabled: !controller.isCancelling) {
                controller.submitPayerOTP(code)
            }
            LinkButton(title: strings.payerOTPChangeMethod, style: style) {
                controller.leavePayerOTP()
            }
            .frame(maxWidth: .infinity)
        }
        // Digits of any script, decimal digits only, never more than the code takes; pasting fills it.
        .onChange(of: code) { typed in
            let digits = String(Digits.ascii(typed).unicodeScalars.filter { ("0"..."9").contains($0) }
                .map(Character.init).prefix(screen.lengthRange.upperBound))
            if digits != typed { code = digits }
        }
        // An answer refusing the code empties the field; a code failing the local check stays.
        .onChange(of: screen.refusals) { _ in code = "" }
    }

    /// A step, the code to dial and the amount standing out.
    static func text(_ step: PayerOTPScreen.StepLine, style: SheetStyle) -> Text {
        step.parts.reduce(Text("")) { text, part in
            switch part {
            case .text(let value): return text + Text(value)
            case .ussdCode(let value): return text + Text(value).bold()
            case .amount(let value): return text + Text(value).bold()
            }
        }
    }
}

/// One box per digit of the code, over a field that takes the typing and a pasted code; no automatic
/// submission.
@MainActor
struct CodeBoxes: View {
    let label: String
    @Binding var code: String
    let length: Int
    let style: SheetStyle
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: style.unit) {
            Text(label)
                .font(style.label)
                .foregroundColor(style.textSecondary)
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
                    .accessibilityLabel(Text(label))
                HStack(spacing: style.unit * 2) {
                    ForEach(0..<length, id: \.self) { index in
                        Text(digit(at: index))
                            .font(style.input)
                            .foregroundColor(style.text)
                            .frame(maxWidth: .infinity, minHeight: ThemeShape.inputHeight)
                            .background(RoundedRectangle(cornerRadius: style.radius).fill(style.inputBackground))
                            .overlay(RoundedRectangle(cornerRadius: style.radius)
                                .strokeBorder(focused && index == min(code.count, length - 1) ? style.primary : style.inputBorder,
                                              lineWidth: 1))
                    }
                }
                .accessibilityHidden(true)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
        }
    }

    private func digit(at index: Int) -> String {
        let digits = Array(code)
        return index < digits.count ? String(digits[index]) : ""
    }
}
#endif
