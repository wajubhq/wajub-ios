#if os(iOS)
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
        // Without a screen to present from, the checkout still settles (`host_gone`) through its callbacks.
        let presenter = SheetPresenter(host: viewController ?? topViewController(), options: options)
        return try await Checkout.present(options, presenter: presenter, browser: presenter.browser)
    }

    static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Presents the SwiftUI sheet modally and turns UIKit dismissals into checkout events.
@MainActor
final class SheetPresenter: NSObject, CheckoutPresenting, UIAdaptivePresentationControllerDelegate {
    /// How many times a presentation waits for a transition running on the host before giving up.
    private static let maxWaits = 40
    private weak var host: UIViewController?
    private let options: PresentOptions
    private var sheet: CheckoutHostingController?
    private var foregroundObserver: NSObjectProtocol?
    let browser = SystemBrowser()

    init(host: UIViewController?, options: PresentOptions) {
        self.host = host
        self.options = options
    }

    func present(_ controller: CheckoutController) {
        present(controller, waits: 0)
    }

    /// Presents from the top of the host's stack once no transition runs there. UIKit drops a
    /// presentation it cannot make without telling anyone: a dropped one settles the checkout.
    private func present(_ controller: CheckoutController, waits: Int) {
        guard controller.result == nil else { return }
        guard var top = host, top.viewIfLoaded?.window != nil else {
            controller.hostGone()
            return
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let transitioning = top.presentedViewController != nil || top.isBeingPresented || top.isBeingDismissed
            || top.transitionCoordinator != nil
        if transitioning {
            guard waits < SheetPresenter.maxWaits else {
                controller.hostGone()
                return
            }
            let retry: @MainActor @Sendable () -> Void = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.present(controller, waits: waits + 1)
            }
            let coordinator = top.presentedViewController?.transitionCoordinator ?? top.transitionCoordinator
            let queued = coordinator?.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in retry() }
            } ?? false
            if !queued {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    retry()
                }
            }
            return
        }
        let sheet = makeSheet(for: controller, host: top)
        top.present(sheet, animated: true)
        guard top.presentedViewController === sheet else {
            // Refused by UIKit: nothing is on screen.
            self.sheet = nil
            controller.hostGone()
            return
        }
        // Back from a wallet's app or the browser (not after Face ID or Control Center, which never leave the app).
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak controller] _ in
            Task { @MainActor in controller?.appWillEnterForeground() }
        }
    }

    private func makeSheet(for controller: CheckoutController, host: UIViewController) -> CheckoutHostingController {
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
            sheet?.isModalInPresentation = controller?.isWorking ?? false
        }
        let browser = self.browser
        sheet.onAppear = { [weak browser] in browser?.sheetDidAppear() }
        browser.sheet = sheet
        self.sheet = sheet
        return sheet
    }

    /// Dismissing from the presenter removes the sheet and Safari above it, if it is open; `completion`
    /// runs once both are gone.
    func dismiss(_ controller: CheckoutController, completion: @escaping @MainActor @Sendable () -> Void) {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        dismissSheet(completion: completion, tries: 0)
    }

    /// UIKit ignores a dismissal asked while a transition runs in the stack (the sheet or Safari coming
    /// or going): wait for it, and try again if the dismissal still did not start.
    private func dismissSheet(completion: @escaping @MainActor @Sendable () -> Void, tries: Int) {
        guard let sheet, let presenting = sheet.presentingViewController else {
            completion()
            return
        }
        if sheet.isBeingDismissed {
            let queued = sheet.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in completion() }
            } ?? false
            if !queued { completion() }
            return
        }
        let retry: @MainActor @Sendable () -> Void = { [weak self] in
            self?.dismissSheet(completion: completion, tries: tries + 1)
        }
        var top: UIViewController = sheet
        while let presented = top.presentedViewController {
            top = presented
        }
        let transitioning = sheet.isBeingPresented || top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil
        if transitioning && tries < SheetPresenter.maxWaits {
            let queued = top.transitionCoordinator?.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in retry() }
            } ?? false
            if !queued {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    retry()
                }
            }
            return
        }
        presenting.dismiss(animated: true) {
            Task { @MainActor in completion() }
        }
        guard tries < SheetPresenter.maxWaits else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Still presented and not leaving: the dismissal was dropped.
            guard let sheet = self?.sheet, sheet.presentingViewController != nil, !sheet.isBeingDismissed else { return }
            retry()
        }
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
    var onAppear: (() -> Void)?

    init(model: CheckoutViewModel) {
        self.model = model
        super.init(rootView: CheckoutSheetView(model: model))
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

    /// While the sheet is off screen (swiped away, covered by Safari, or its host's stack torn down or
    /// taken out of the window), the checkout checks twice a second whether it, or what covers it, is
    /// still on screen; gone twice in a row and the checkout not settled, the host went away. A swipe
    /// settles the checkout itself first (or its cancel does).
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.controller.watchHost { [weak self] in
            guard let self else { return nil }
            if self.viewIfLoaded?.window != nil { return .shown }
            var top: UIViewController = self
            while let presented = top.presentedViewController {
                top = presented
            }
            return self.presentingViewController == nil || top.viewIfLoaded?.window == nil ? .gone : .covered
        }
    }
}

/// Opens provider pages: `SFSafariViewController` over the sheet, or the system (`UIApplication.open`)
/// for a wallet's page that opens its app. Never a WebView.
@MainActor
final class SystemBrowser: NSObject, BrowserOpening, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    weak var sheet: UIViewController?
    private var onClose: (@MainActor @Sendable () -> Void)?
    private var returnObserver: NSObjectProtocol?

    func open(_ url: URL, mode: BrowserMode, onClose: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        if mode == .inApp, let sheet, sheet.presentedViewController == nil, sheet.viewIfLoaded?.window != nil,
           !sheet.isBeingPresented, !sheet.isBeingDismissed {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            safari.delegate = self
            self.onClose = onClose
            sheet.present(safari, animated: true)
            safari.presentationController?.delegate = self
            return true
        }
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { opened in
                continuation.resume(returning: opened)
            }
        }
        if opened && mode == .inApp {
            // Asked for in the app but handed to the system: the payer is back when the app is.
            self.onClose = onClose
            returnObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closed() }
            }
        }
        return opened
    }

    /// "Close" in Safari.
    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor in self.closed() }
    }

    /// Safari swiped down.
    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in self.closed() }
    }

    /// The sheet is visible again: Safari is gone even if no delegate call said so.
    func sheetDidAppear() {
        if onClose != nil, sheet?.presentedViewController == nil { closed() }
    }

    private func closed() {
        if let returnObserver { NotificationCenter.default.removeObserver(returnObserver) }
        returnObserver = nil
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
