#if os(iOS)
import SwiftUI
import UIKit
import WajubMobile

/// The method list (`INITIATED`).
@MainActor
struct MethodListView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        VStack(alignment: .leading, spacing: style.gapRow) {
            Text(model.strings.chooseMethod)
                .font(style.label)
                .foregroundColor(style.textSecondary)
            ForEach(controller.methods) { method in
                Button {
                    controller.selectMethod(method.id)
                } label: {
                    row(method)
                }
                .buttonStyle(.plain)
                .disabled(!method.isEnabled)
            }
            FormFooter(model: model, style: style)
        }
    }

    private func row(_ method: CheckoutMethod) -> some View {
        HStack(spacing: style.gapColumn) {
            MethodLogo(method: method, style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(method.name)
                    .font(style.body)
                    .foregroundColor(style.text)
                if let limit = method.limit {
                    Text(limitText(limit))
                        .font(style.hint)
                        .foregroundColor(style.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(style.textPlaceholder)
        }
        .padding(.horizontal, style.unit * 3)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: style.radius).fill(style.inputBackground))
        .overlay(RoundedRectangle(cornerRadius: style.radius).strokeBorder(style.inputBorder, lineWidth: 1))
        .opacity(method.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    private func limitText(_ limit: AmountLimit) -> String {
        switch limit {
        case .minimum(let amount): return model.strings.minimum(model.controller.formatAmount(amount))
        case .maximum(let amount): return model.strings.maximum(model.controller.formatAmount(amount))
        }
    }
}

/// "Other payment methods" and "Cancel payment" under a form.
@MainActor
struct FormFooter: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        HStack {
            if controller.canGoBack {
                LinkButton(title: model.strings.otherMethods, style: style) { controller.backToMethods() }
            }
            Spacer()
            if controller.canCancelPayment {
                LinkButton(title: model.strings.cancelPayment, style: style, color: style.textSecondary) { controller.cancelPayment() }
            }
        }
    }
}

/// The form of the chosen method (`COLLECTING_DETAILS` / `PROCESSING`).
@MainActor
struct MethodFormView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        VStack(alignment: .leading, spacing: style.gapRow) {
            switch controller.currentMethod?.kind {
            case .mobileMoney? where controller.payerOTP != nil:
                PayerOTPView(model: model, style: style, screen: controller.payerOTP!)
            case .mobileMoney?:
                MobileMoneyFormView(model: model, style: style)
            case .card(let flavour)?:
                CardFormView(model: model, style: style, flavour: flavour)
            case .wallet?:
                WalletView(model: model, style: style)
            case nil:
                EmptyView()
            }
            if let banner = controller.banner {
                BannerView(message: banner.message, foreground: style.danger, background: style.dangerBackground, style: style)
            }
            FormFooter(model: model, style: style)
        }
    }
}

/// Country, number with its dial code, operator picker (README §6).
@MainActor
struct MobileMoneyFormView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        if let form = controller.mobileMoney {
            VStack(alignment: .leading, spacing: style.gapRow) {
                if !form.countryLocked && form.countries.count > 1 {
                    countryPicker(form)
                }
                phoneField(form)
                // Every operator out of its limits is still listed, with its limit.
                if !form.choices.isEmpty && (form.isOperatorListVisible || form.hasNoOperator) {
                    operatorList(form)
                }
                if form.choices.isEmpty {
                    BannerView(message: model.strings.errorMessage(WajubError.Code.operatorUnavailable), foreground: style.warning,
                               background: style.warningBackground, style: style)
                }
                if let unavailable = form.unavailableDetected, let limit = unavailable.limit {
                    BannerView(message: model.strings.operatorOutOfLimits(unavailable.label, limit: limitText(limit)),
                               foreground: style.warning, background: style.warningBackground, style: style)
                }
                if let announced = form.announcedPayerOTP {
                    Text(model.strings.payerOTPFormHint(ussdCode: announced.ussdCode))
                        .font(style.hint)
                        .foregroundColor(style.textSecondary)
                }
                PrimaryButton(title: model.strings.pay(controller.formattedAmount), style: style, busy: controller.isPaying,
                              enabled: !form.hasNoOperator && !controller.isCancelling) {
                    controller.submitMobileMoney()
                }
            }
        }
    }

    private func countryPicker(_ form: MobileMoneyForm) -> some View {
        FieldBox(label: model.strings.country, error: nil, style: style) {
            Menu {
                ForEach(form.countries, id: \.self) { code in
                    Button(MobileMoneyData.shared.countries[code]?.name ?? code) {
                        model.controller.setCountry(code)
                    }
                }
            } label: {
                HStack {
                    Text(MobileMoneyData.shared.countries[form.country]?.name ?? form.country)
                        .font(style.input)
                        .foregroundColor(style.text)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(style.textSecondary)
                }
            }
        }
    }

    private func phoneField(_ form: MobileMoneyForm) -> some View {
        let controller = model.controller
        return FieldBox(label: model.strings.mobileMoneyNumber, error: controller.fieldErrors["data.phone"]?.message, style: style) {
            HStack(spacing: style.unit * 2) {
                Text(form.dialCode)
                    .font(style.input)
                    .foregroundColor(style.textSecondary)
                PhoneInput(model: model, style: style, placeholder: form.placeholder)
                if form.operatorMode == .detect && !form.isOperatorListVisible, let badge = form.badgeChoice {
                    OperatorLogo(choice: badge, size: 24)
                    if form.choices.count > 1 {
                        LinkButton(title: model.strings.changeOperator, style: style) { controller.openOperatorList() }
                    }
                }
            }
        }
    }

    private func operatorList(_ form: MobileMoneyForm) -> some View {
        let controller = model.controller
        return VStack(alignment: .leading, spacing: style.unit * 2) {
            Text(model.strings.mobileMoneyOperator)
                .font(style.label)
                .foregroundColor(style.textSecondary)
            ForEach(form.choices) { choice in
                let selected = choice.id == form.selection
                Button {
                    controller.pickOperator(choice.id)
                } label: {
                    HStack(spacing: style.gapColumn) {
                        OperatorLogo(choice: choice)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label)
                                .font(style.body)
                                .foregroundColor(style.text)
                            if let limit = choice.limit {
                                Text(limitText(limit))
                                    .font(style.hint)
                                    .foregroundColor(style.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(selected ? style.primary : style.inputBorder)
                    }
                    .padding(.horizontal, style.unit * 3)
                    .frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: style.radius).fill(selected ? style.selected : style.inputBackground))
                    .overlay(RoundedRectangle(cornerRadius: style.radius)
                        .strokeBorder(selected ? style.primary : style.inputBorder, lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                    .opacity(choice.limit == nil ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(choice.limit != nil)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if let error = controller.fieldErrors["data.operator"] {
                Text(error.message)
                    .font(style.hint)
                    .foregroundColor(style.danger)
            }
        }
    }

    private func limitText(_ limit: AmountLimit) -> String {
        switch limit {
        case .minimum(let amount): return model.strings.minimum(model.controller.formatAmount(amount))
        case .maximum(let amount): return model.strings.maximum(model.controller.formatAmount(amount))
        }
    }
}

/// The number field: what the payer types stays in the field, then shows formatted as you type.
@MainActor
struct PhoneInput: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let placeholder: String
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .font(style.input)
            .foregroundColor(style.text)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .onAppear {
                text = model.controller.mobileMoney?.formattedPhone ?? ""
            }
            .onChange(of: text) { typed in
                model.controller.setPhone(typed)
                let formatted = model.controller.mobileMoney?.formattedPhone ?? ""
                if formatted != typed { text = formatted }
            }
    }
}

/// The card form: Stripe (the host's collector), a hosted page's fields, or the sandbox test card.
@MainActor
struct CardFormView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let flavour: CardFlavour

    var body: some View {
        let controller = model.controller
        let strings = model.strings
        VStack(alignment: .leading, spacing: style.gapRow) {
            if let form = controller.cardForm {
                ForEach(form.fields, id: \.self) { field in
                    InputField(label: label(field), text: binding(field), error: controller.fieldErrors[field]?.message, style: style,
                               keyboard: keyboard(field), contentType: contentType(field), secure: field == "cvv")
                }
            }
            switch flavour {
            case .sandboxForm:
                BannerView(message: strings.sandboxCardHint, foreground: style.warning, background: style.warningBackground, style: style)
            case .clientSession, .hostedRedirect:
                Text(strings.cardRedirectHint)
                    .font(style.hint)
                    .foregroundColor(style.textSecondary)
            case .stripe:
                EmptyView()
            }
            PrimaryButton(title: isStripe ? strings.payByCard : strings.pay(controller.formattedAmount), style: style,
                          busy: controller.isPaying, enabled: !controller.isCancelling) {
                controller.submitCard()
            }
        }
    }

    private var isStripe: Bool {
        if case .stripe = flavour { return true }
        return false
    }

    private func binding(_ field: String) -> Binding<String> {
        let controller = model.controller
        return Binding(get: { controller.cardForm?.values[field] ?? "" }, set: { controller.setCardField(field, $0) })
    }

    private func label(_ field: String) -> String {
        let strings = model.strings
        switch field {
        case "card.number": return strings.cardNumber
        case "card_holder": return strings.cardHolder
        case "expiry_month": return strings.expiryMonth
        case "expiry_year": return strings.expiryYear
        case "cvv": return strings.cvv
        default: return strings.fieldLabel(field)
        }
    }

    private func keyboard(_ field: String) -> UIKeyboardType {
        switch field {
        case "email": return .emailAddress
        case "phone": return .phonePad
        case "card.number", "expiry_month", "expiry_year", "cvv": return .numberPad
        default: return .default
        }
    }

    private func contentType(_ field: String) -> UITextContentType? {
        switch field {
        case "email": return .emailAddress
        case "first_name": return .givenName
        case "last_name": return .familyName
        case "phone": return .telephoneNumber
        case "address": return .streetAddressLine1
        case "city": return .addressCity
        case "state": return .addressState
        case "zip_code": return .postalCode
        case "card.number": return .creditCardNumber
        case "card_holder": return .name
        case "cvv":
            // Not a password to save in the keychain.
            if #available(iOS 17.0, *) { return .creditCardSecurityCode }
            return .oneTimeCode
        default: return nil
        }
    }
}

/// One-tap wallet: the wallet's page opens its app.
@MainActor
struct WalletView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        let name = controller.currentMethod?.name ?? ""
        VStack(alignment: .leading, spacing: style.gapRow) {
            if let method = controller.currentMethod {
                HStack(spacing: style.gapColumn) {
                    MethodLogo(method: method, style: style, size: 40)
                    Text(name)
                        .font(style.title)
                        .foregroundColor(style.text)
                }
            }
            Text(model.strings.walletHint(name))
                .font(style.body)
                .foregroundColor(style.textSecondary)
            PrimaryButton(title: model.strings.payWith(name), style: style, busy: controller.isPaying,
                          enabled: !controller.isCancelling) {
                controller.payWallet()
            }
        }
    }
}

#endif
