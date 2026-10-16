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
                        }
                    }
                }
            }
            FieldBox(label: strings.payerOTPAmount, error: nil, style: style) {
                Text(screen.exactAmount)
                    .font(style.input)
                    .foregroundColor(style.text)
                    .textSelection(.enabled)
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
            InputField(label: strings.payerOTPCodeLabel, text: $code, error: nil, style: style, keyboard: .numberPad,
                       contentType: .oneTimeCode)
                .onChange(of: code) { typed in
                    let digits = String(typed.filter(\.isNumber).prefix(screen.lengthRange.upperBound))
                    if digits != typed { code = digits }
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
        .onChange(of: screen.message) { _ in code = "" }
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
#endif
