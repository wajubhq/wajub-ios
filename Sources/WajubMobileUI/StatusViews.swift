#if os(iOS)
import SwiftUI
import UIKit
import WajubMobile

/// A spinner with a line of text: the sheet is waiting for the payment.
@MainActor
struct WaitingRow: View {
    let text: String
    let style: SheetStyle

    var body: some View {
        HStack(spacing: style.unit * 2) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(style.primary)
            Text(text)
                .font(style.hint)
                .foregroundColor(style.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, style.unit * 2)
    }
}

/// The API's (English) instruction: the main text of an English sheet, under "Instructions" in French.
@MainActor
struct InstructionView: View {
    let instruction: String
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.unit) {
            if model.strings.language == .fr {
                Text(model.strings.instructions)
                    .font(style.label)
                    .foregroundColor(style.textSecondary)
            }
            Text(instruction)
                .font(model.strings.language == .fr ? style.hint : style.body)
                .foregroundColor(style.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(style.unit * 3)
        .background(RoundedRectangle(cornerRadius: style.radius).fill(style.surfaceMuted))
    }
}

/// "Approve the payment on your phone" (`APPROVAL_REQUIRED`).
@MainActor
struct ApprovalView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let approval: ApprovalScreen

    var body: some View {
        let strings = model.strings
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: "iphone.radiowaves.left.and.right", tint: style.primary, title: strings.approvalTitle,
                          message: strings.approvalBody(amount: model.controller.formattedAmount, phone: approval.phone), style: style)
            if let instruction = approval.instruction {
                InstructionView(instruction: instruction, model: model, style: style)
            }
            WaitingRow(text: strings.waitingForApproval, style: style)
        }
    }
}

/// "Dial this code" (`USSD_REQUIRED`).
@MainActor
struct UssdView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let instruction: String?

    var body: some View {
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: "phone.arrow.up.right", tint: style.primary, title: model.strings.ussdTitle, message: nil, style: style)
            if let instruction {
                InstructionView(instruction: instruction, model: model, style: style)
            }
            WaitingRow(text: model.strings.waitingForApproval, style: style)
        }
    }
}

/// A confirmation step: OTP, PIN, phone, date of birth or billing address.
@MainActor
struct StepView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let step: StepScreen

    @State private var code = ""
    @State private var phone = ""
    @State private var birthday = Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: Date()) ?? Date()
    /// The date is sent only once the payer has picked one.
    @State private var birthdayPicked = false
    @State private var address = ""
    @State private var city = ""
    @State private var region = ""
    @State private var zipCode = ""

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(alignment: .leading, spacing: style.gapRow) {
            Text(strings.stepTitle(step.kind))
                .font(style.title)
                .foregroundColor(style.text)
            if let hint = step.hint {
                Text(step.kind == .otp ? strings.codeSentTo(hint) : hint)
                    .font(style.hint)
                    .foregroundColor(style.textSecondary)
            } else if step.kind == .otp {
                Text(strings.codeSent)
                    .font(style.hint)
                    .foregroundColor(style.textSecondary)
            }
            fields
            if let error = step.error {
                BannerView(message: error.message, foreground: style.danger, background: style.dangerBackground, style: style)
            }
            PrimaryButton(title: strings.confirm, style: style, busy: controller.isWorking) {
                controller.submitStep(values)
            }
            if step.kind == .otp || step.kind == .pin || step.kind == .phone {
                ResendButton(availableAt: step.resendAvailableAt, model: model, style: style) { controller.resendStepCode() }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        let errors = model.controller.fieldErrors
        let strings = model.strings
        switch step.kind {
        case .otp:
            InputField(label: strings.code, text: $code, error: errors["code"]?.message, style: style, keyboard: .numberPad,
                       contentType: .oneTimeCode)
        case .pin:
            InputField(label: strings.pin, text: $code, error: errors["pin"]?.message, style: style, keyboard: .numberPad, secure: true)
        case .phone:
            InputField(label: strings.fieldLabel("phone"), text: $phone, error: errors["phone"]?.message, style: style,
                       keyboard: .phonePad, contentType: .telephoneNumber)
        case .birthday:
            FieldBox(label: strings.birthday, error: errors["birthday"]?.message, style: style) {
                DatePicker(strings.birthday, selection: $birthday, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: birthday) { _ in birthdayPicked = true }
            }
        case .address:
            InputField(label: strings.fieldLabel("address"), text: $address, error: errors["address"]?.message, style: style,
                       contentType: .streetAddressLine1)
            InputField(label: strings.fieldLabel("city"), text: $city, error: errors["city"]?.message, style: style, contentType: .addressCity)
            InputField(label: strings.fieldLabel("state"), text: $region, error: errors["state"]?.message, style: style,
                       contentType: .addressState)
            InputField(label: strings.fieldLabel("zip_code"), text: $zipCode, error: errors["zip_code"]?.message, style: style,
                       contentType: .postalCode)
        }
    }

    private var values: [String: String] {
        switch step.kind {
        case .otp: return ["code": code]
        case .pin: return ["pin": code]
        case .phone: return ["phone": phone]
        case .birthday: return ["birthday": birthdayPicked ? StepView.dayFormatter.string(from: birthday) : ""]
        case .address: return ["address": address, "city": city, "state": region, "zip_code": zipCode]
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// "Resend code", offered once its countdown ends.
@MainActor
struct ResendButton: View {
    let availableAt: Date
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let action: () -> Void

    var body: some View {
        Countdown(until: availableAt) { seconds in
            if seconds > 0 {
                Text(model.strings.resendIn(seconds))
                    .font(style.hint)
                    .foregroundColor(style.textPlaceholder)
                    .frame(maxWidth: .infinity, minHeight: ThemeShape.inputHeight)
            } else {
                LinkButton(title: model.strings.resendCode, style: style, action: action)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The sandbox 3-D Secure email code (`3DS_REQUIRED`, then `VERIFYING`).
@MainActor
struct ThreeDSView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let challenge: ThreeDSScreen
    @State private var code = ""

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(alignment: .leading, spacing: style.gapRow) {
            Text(strings.threeDSTitle)
                .font(style.title)
                .foregroundColor(style.text)
            if let email = challenge.maskedEmail {
                Text(strings.threeDSCodeSent(email))
                    .font(style.hint)
                    .foregroundColor(style.textSecondary)
            }
            if challenge.accepted {
                WaitingRow(text: strings.pendingBody, style: style)
            } else {
                InputField(label: strings.code, text: $code, error: controller.fieldErrors["code"]?.message, style: style,
                           keyboard: .numberPad, contentType: .oneTimeCode)
                if let expiresAt = challenge.expiresAt {
                    Countdown(until: expiresAt) { seconds in
                        Text(strings.expiresIn(String(format: "%d:%02d", seconds / 60, seconds % 60)))
                            .font(style.hint)
                            .foregroundColor(style.textSecondary)
                    }
                }
                if let error = challenge.error {
                    BannerView(message: error.message, foreground: style.danger, background: style.dangerBackground, style: style)
                }
                PrimaryButton(title: strings.confirm, style: style, busy: controller.isWorking) {
                    controller.submitThreeDSCode(code)
                }
                ResendButton(availableAt: challenge.resendAvailableAt, model: model, style: style) { controller.resendThreeDSCode() }
            }
        }
    }
}

/// "Payment in progress" (`PENDING`), with "Continue payment" when a provider page can be reopened.
@MainActor
struct PendingView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let pending: PendingScreen

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(spacing: style.gapRow) {
            if pending.capReached {
                OutcomeHeader(symbol: "clock", tint: style.primary, title: strings.pendingTitle, message: strings.pendingCapBody, style: style)
                PrimaryButton(title: strings.close, style: style) { controller.close() }
            } else {
                let inBrowser = pending.continueURL != nil
                OutcomeHeader(symbol: pending.threeDS ? "lock.shield" : "hourglass", tint: style.primary,
                              title: pending.threeDS && controller.isBrowserOpen ? strings.threeDSBrowserTitle : strings.pendingTitle,
                              message: inBrowser ? strings.browserBody : strings.pendingBody, style: style)
                WaitingRow(text: strings.waitingForApproval, style: style)
                if inBrowser {
                    PrimaryButton(title: strings.continuePayment, style: style) { controller.continuePayment() }
                }
            }
        }
    }
}

/// The success screen (`SUCCESS`): it closes itself after `autoCloseSuccess`.
@MainActor
struct SuccessView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let payment: PaymentSuccess

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: "checkmark.circle.fill", tint: style.success, title: strings.successTitle,
                          message: strings.paidTo(amount: controller.formatAmount(payment.amount),
                                                  merchant: controller.session?.branding.businessName),
                          style: style)
            if let reference = payment.reference {
                HStack {
                    Text(strings.reference)
                        .foregroundColor(style.textSecondary)
                    Spacer()
                    Text(reference)
                        .foregroundColor(style.text)
                }
                .font(style.hint)
                .padding(style.unit * 3)
                .background(RoundedRectangle(cornerRadius: style.radius).fill(style.surfaceMuted))
            }
            if let receipt = payment.receiptURL.flatMap(URL.init(string:)) {
                Link(destination: receipt) {
                    Text(strings.viewReceipt)
                        .font(style.label)
                        .foregroundColor(style.primary)
                }
            }
            PrimaryButton(title: strings.close, style: style) { controller.close() }
        }
    }
}

/// The failure screen (`FAILED`): "Try again" when the error is retryable, and Close.
@MainActor
struct FailureView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let error: WajubError

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: "xmark.octagon.fill", tint: style.danger, title: strings.failedTitle, message: error.message, style: style)
            if controller.canTryAgain {
                if let availableAt = controller.retryAvailableAt {
                    Countdown(until: availableAt) { seconds in
                        PrimaryButton(title: seconds > 0 ? strings.tryAgainIn(seconds) : strings.tryAgain, style: style, enabled: seconds == 0) {
                            controller.tryAgain()
                        }
                    }
                } else {
                    PrimaryButton(title: strings.tryAgain, style: style) { controller.tryAgain() }
                }
            }
            LinkButton(title: strings.close, style: style) { controller.close() }
        }
    }
}

/// A payment that ended: at load, expired, or cancelled.
@MainActor
struct EndedView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let error: WajubError?
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: symbol, tint: style.textSecondary, title: title, message: error?.message, style: style)
            PrimaryButton(title: model.strings.close, style: style) { model.controller.close() }
        }
    }

    static func title(_ state: CheckoutState, _ strings: WajubStrings) -> String {
        switch state {
        case .expired: return strings.expiredTitle
        case .cancelled: return strings.cancelledTitle
        default: return strings.endedTitle
        }
    }
}
#endif
