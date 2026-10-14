#if canImport(UIKit) && canImport(SwiftUI)
import SafariServices
import SwiftUI
import UIKit
import WajubMobile

/// The native payment sheet.
///
/// ```swift
/// var options = PresentOptions(sessionToken: authorizationToken)
/// options.callbacks.onSuccess = { payment in print(payment.id) }
/// let result = try await WajubCheckout.present(options, from: self)
/// ```
@MainActor
public enum WajubCheckout {
    /// Presents the sheet over `viewController` (by default the top-most view controller of the key
    /// window) and resolves exactly once, when it closes.
    ///
    /// Throws `WajubError` `sheet_already_presented` at once when a sheet is already open. Confirm a
    /// `complete` result server-side before you deliver.
    public static func present(_ options: PresentOptions, from viewController: UIViewController? = nil) async throws -> CheckoutResult {
        guard let host = viewController ?? topViewController() else {
            return .cancelled(reason: .hostGone, redirectURL: nil)
        }
        let presenter = SheetPresenter(host: host, options: options)
        return try await Checkout.present(options, presenter: presenter, browser: presenter.browser)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Presents the SwiftUI sheet modally and turns UIKit dismissals into checkout events.
@MainActor
final class SheetPresenter: NSObject, CheckoutPresenting, UIAdaptivePresentationControllerDelegate {
    private weak var host: UIViewController?
    private let options: PresentOptions
    private var sheet: CheckoutHostingController?
    private var foregroundObserver: NSObjectProtocol?
    let browser = SystemBrowser()

    init(host: UIViewController, options: PresentOptions) {
        self.host = host
        self.options = options
    }

    func present(_ controller: CheckoutController) {
        guard let host else {
            controller.hostGone()
            return
        }
        let inherited = options.appearance?.inherit == true ? InheritedThemeReader.read(from: host) : nil
        let model = CheckoutViewModel(controller: controller, inherited: inherited)
        let sheet = CheckoutHostingController(model: model)
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = true
        }
        sheet.presentationController?.delegate = self
        model.onSchemePreference = { [weak sheet] scheme in
            switch scheme {
            case .dark?: sheet?.overrideUserInterfaceStyle = .dark
            case .light?: sheet?.overrideUserInterfaceStyle = .light
            case nil: sheet?.overrideUserInterfaceStyle = .unspecified
            }
        }
        // No swipe-down while a request runs.
        model.onUpdate = { [weak sheet, weak controller] in
            sheet?.isModalInPresentation = controller?.isBusy ?? false
        }
        browser.sheet = sheet
        self.sheet = sheet
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak controller] _ in
            Task { @MainActor in controller?.appDidBecomeActive() }
        }
        host.present(sheet, animated: true)
    }

    func dismiss(_ controller: CheckoutController) {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        guard let sheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed else { return }
        sheet.dismiss(animated: true)
    }

    /// The payer swiped the sheet down.
    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in self.sheet?.model.controller.dismiss() }
    }
}

/// The sheet's view controller: settles the checkout when it disappears for any other reason
/// (the presenting screen went away).
final class CheckoutHostingController: UIHostingController<CheckoutSheetView> {
    let model: CheckoutViewModel

    init(model: CheckoutViewModel) {
        self.model = model
        super.init(rootView: CheckoutSheetView(model: model))
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        // A swipe reaches `presentationControllerDidDismiss` right after this and dismisses the
        // checkout itself: give it a moment before deciding the host went away.
        let controller = model.controller
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if controller.result == nil && !controller.isClosing {
                controller.hostGone()
            }
        }
    }
}

/// Opens provider pages: `SFSafariViewController` over the sheet, or the system (`UIApplication.open`)
/// for a wallet's page that opens its app. Never a WebView.
@MainActor
final class SystemBrowser: NSObject, BrowserOpening, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    weak var sheet: UIViewController?
    private var onClose: (@MainActor () -> Void)?

    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor () -> Void) async -> Bool {
        if mode == .inApp, let sheet, sheet.presentedViewController == nil {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            safari.delegate = self
            self.onClose = onClose
            sheet.present(safari, animated: true)
            safari.presentationController?.delegate = self
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    /// "Close" in Safari.
    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor in self.closed() }
    }

    /// Safari swiped down.
    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in self.closed() }
    }

    private func closed() {
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }
}

/// Reads the presenting screen's theme for `appearance.inherit` (appearance.md §3).
enum InheritedThemeReader {
    @MainActor
    static func read(from viewController: UIViewController) -> InheritedTheme {
        let traits = viewController.traitCollection
        func color(_ color: UIColor?) -> RGBAColor? {
            guard let resolved = color?.resolvedColor(with: traits) else { return nil }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
            return RGBAColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        }
        let scheme: ColorSchemeKind?
        switch traits.userInterfaceStyle {
        case .dark: scheme = .dark
        case .light: scheme = .light
        default: scheme = nil
        }
        return InheritedTheme(scheme: scheme, primary: color(viewController.view.tintColor), background: color(.systemBackground),
                              text: color(.label), textSecondary: color(.secondaryLabel), inputBorder: color(.separator))
    }
}
#endif
