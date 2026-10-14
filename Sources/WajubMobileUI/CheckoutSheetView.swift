#if os(iOS)
import SwiftUI
import UIKit
import WajubMobile

/// The sheet: merchant header, the current screen, "Secured by Wajub".
@MainActor
struct CheckoutSheetView: View {
    @ObservedObject var model: CheckoutViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Declared so a text-size change redraws the sheet (fonts are scaled with Dynamic Type).
    @Environment(\.sizeCategory) private var sizeCategory

    var body: some View {
        let style = SheetStyle(theme: model.theme(system: colorScheme), reduceMotion: reduceMotion)
        VStack(spacing: 0) {
            SheetHeader(model: model, style: style)
            ScrollView {
                ScreenView(model: model, style: style)
                    .padding(.horizontal, style.unit * 5)
                    .padding(.vertical, style.unit * 4)
                    .frame(maxWidth: .infinity)
                    // Number pads have no Return key: a tap between the fields closes the keyboard.
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture {
                        WajubCheckout.keyWindow()?.endEditing(true)
                    })
                    .id(ScreenView.key(model.controller.screen))
                    .transition(.opacity)
            }
            SheetFooter(model: model, style: style)
        }
        .background(style.background.ignoresSafeArea())
        .animation(style.animates ? .easeInOut(duration: 0.2) : nil, value: ScreenView.key(model.controller.screen))
    }
}

/// The merchant's logo or name, the amount, and the close button.
@MainActor
struct SheetHeader: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        let controller = model.controller
        VStack(alignment: .leading, spacing: style.unit * 2) {
            HStack(alignment: .center, spacing: style.unit * 2) {
                merchant
                Spacer()
                if controller.isSandbox {
                    Text(model.strings.testMode)
                        .font(style.hint)
                        .foregroundColor(style.warning)
                        .padding(.horizontal, style.unit * 2)
                        .padding(.vertical, style.unit)
                        .background(Capsule().fill(style.warningBackground))
                }
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(style.textSecondary)
                        .frame(width: ThemeShape.inputHeight, height: ThemeShape.inputHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(model.strings.close))
            }
            if controller.session != nil {
                Text(controller.formattedAmount)
                    .font(style.amount)
                    .foregroundColor(style.text)
                if controller.session?.transaction.bearer == "customer" {
                    Text(model.strings.feesIncluded)
                        .font(style.hint)
                        .foregroundColor(style.textSecondary)
                }
            }
        }
        .padding(.horizontal, style.unit * 5)
        .padding(.top, style.unit * 5)
        .padding(.bottom, style.unit * 2)
    }

    @ViewBuilder private var merchant: some View {
        let branding = model.controller.session?.branding
        if let url = branding?.headerLogoURL.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    merchantName(branding?.businessName)
                }
            }
            .frame(maxWidth: 160, maxHeight: 40, alignment: .leading)
        } else {
            merchantName(branding?.businessName)
        }
    }

    private func merchantName(_ name: String?) -> some View {
        Text(name ?? "")
            .font(style.label)
            .foregroundColor(style.text)
            .lineLimit(1)
    }
}

/// "Secured by Wajub", hidden by `white_label`.
@MainActor
struct SheetFooter: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        if !style.theme.hidesWajubBranding {
            HStack(spacing: style.unit) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text(model.strings.securedByWajub)
                    .font(style.hint)
            }
            .foregroundColor(style.textPlaceholder)
            .frame(maxWidth: .infinity)
            .padding(.vertical, style.unit * 3)
        }
    }
}

/// Draws `CheckoutController.screen`.
@MainActor
struct ScreenView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle

    var body: some View {
        switch model.controller.screen {
        case .loading:
            if model.controller.options.loader == .spinner {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(style.primary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                SkeletonView(style: style, label: model.strings.loading)
            }
        case .loadError(let error):
            LoadErrorView(model: model, style: style, error: error)
        case .methods:
            MethodListView(model: model, style: style)
        case .form:
            MethodFormView(model: model, style: style)
        case .approval(let approval):
            ApprovalView(model: model, style: style, approval: approval)
        case .ussd(let instruction):
            UssdView(model: model, style: style, instruction: instruction)
        case .step(let step):
            StepView(model: model, style: style, step: step)
                .id(step.id + step.kind.rawValue)
        case .threeDS(let challenge):
            ThreeDSView(model: model, style: style, challenge: challenge)
                .id(challenge.id)
        case .pending(let pending):
            PendingView(model: model, style: style, pending: pending)
        case .success(let payment):
            SuccessView(model: model, style: style, payment: payment)
        case .failed(let error):
            FailureView(model: model, style: style, error: error)
        case .ended(let error, let state):
            EndedView(model: model, style: style, error: error, title: EndedView.title(state, model.strings),
                      symbol: state == .expired ? "clock" : "xmark.circle")
        case .expired(let error):
            EndedView(model: model, style: style, error: error, title: model.strings.expiredTitle, symbol: "clock")
        case .cancelled(let error):
            EndedView(model: model, style: style, error: error, title: model.strings.cancelledTitle, symbol: "xmark.circle")
        }
    }

    /// Identifies a screen for the cross-fade.
    static func key(_ screen: CheckoutScreen) -> String {
        switch screen {
        case .loading: return "loading"
        case .loadError: return "loadError"
        case .methods: return "methods"
        case .form: return "form"
        case .approval: return "approval"
        case .ussd: return "ussd"
        case .step(let step): return "step-\(step.id)"
        case .threeDS(let challenge): return "3ds-\(challenge.id)"
        case .pending: return "pending"
        case .success: return "success"
        case .failed: return "failed"
        case .ended: return "ended"
        case .expired: return "expired"
        case .cancelled: return "cancelled"
        }
    }
}

/// A load error: Retry when it is retryable, and Close.
@MainActor
struct LoadErrorView: View {
    @ObservedObject var model: CheckoutViewModel
    let style: SheetStyle
    let error: WajubError

    var body: some View {
        VStack(spacing: style.gapRow) {
            OutcomeHeader(symbol: "exclamationmark.triangle", tint: style.danger, title: model.strings.loadErrorTitle,
                          message: error.message, style: style)
            if error.retryable {
                PrimaryButton(title: model.strings.retry, style: style) { model.controller.retryLoad() }
            }
            LinkButton(title: model.strings.close, style: style) { model.controller.close() }
        }
    }
}
#endif
