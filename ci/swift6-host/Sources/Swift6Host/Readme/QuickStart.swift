// README › Quick start, verbatim (ReadmeTests compares them). Lines marked `// wrapper` are not in the README.
#if os(iOS) // wrapper
import UIKit
import WajubMobile
import WajubMobileUI

@MainActor
func pay(token: String, from viewController: UIViewController) async {
    var options = PresentOptions(sessionToken: token)
    options.returnURL = "https://shop.example.com/app/return"   // optional, a universal link into your app
    options.callbacks.onStateChange = { event in print("checkout:", event.state.rawValue) }

    do {
        switch try await WajubCheckout.present(options, from: viewController) {
        case .complete(let payment, _):
            // Paid. Confirm on your server (GET /payments/{id} or the payment.succeeded webhook) before delivering.
            await confirmOnServer(paymentId: payment.id)
        case .processing:
            // The payer left while a payment was running: your server learns the outcome from the webhook.
            break
        case .failed(let error, _):
            print(error.code, error.message)
        case .cancelled(let reason, _):
            print("cancelled:", reason.rawValue)
        }
    } catch let error as WajubError {
        // Only `sheet_already_presented`: a sheet is already open.
        print(error.message)
    } catch {}
}

/// The app's own call to its server.
func confirmOnServer(paymentId: String) async {}
#endif // wrapper
