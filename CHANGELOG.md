# Changelog

## 1.0.0 (unreleased)

- First release of the Wajub iOS SDK, a Swift package for iOS 15 and later with two products:
  `WajubMobile` (the API client and the checkout's logic, Foundation only) and `WajubMobileUI` (the
  SwiftUI payment sheet). It implements the shared mobile contract, spec v2, with the same names as
  Wajub.js 1.8: `PresentOptions`, `CheckoutCallbacks`, `CheckoutResult`, `CheckoutState`,
  `PaymentSuccess`, `WajubError` and `Appearance`.
- `WajubCheckout.present(_:from:)` presents the sheet and resolves exactly once with a
  `CheckoutResult` (`complete`, `processing`, `failed` or `cancelled`) when the sheet is gone, so the
  next `present` can follow at once (one called from `onComplete` waits for the sheet to be gone).
  Presenting a second sheet while one is open throws `sheet_already_presented`; a sheet with no
  screen to present from, or whose presenting screen goes away, resolves at once (`host_gone`), even
  while "Cancel payment" runs.
- Mobile Money: country, number with its dial code formatted as you type, operator picker with
  logos or brand badges, the operators of an aggregate such as `cm.mobile`, detection of the
  operator from the number, a clear message when the number belongs to another operator, numbers
  sent in E.164 (Côte d'Ivoire keeps its leading 0), and an approval screen with the operator's
  instruction while the payer confirms on the phone.
- Cards: provider-hosted sessions (Paystack, Flutterwave, Adyen), hosted card pages with the fields
  the provider asks for, the sandbox test card, and Stripe through a `CardCollector` you implement
  with Stripe's SDK (WajubMobile does not depend on it). Provider pages open in Safari, never in a
  WebView, and the payment is checked as soon as the payer comes back.
- One-tap wallets such as Djamo, and Wave's redirect.
- Closing the sheet cancels the payment (`POST /pay/cancel`) only when nothing can still move: its
  last known status is `pending` and no attempt is undecided (from the Pay press until a definitive
  answer: a decline, a step or 3-D Secure failed for good, a refused card session, a `pending` with a
  new `error_code`). Otherwise closing resolves `processing`, or `failed` on a failure screen; after
  a definitive refusal "Cancel payment" is offered again. A payment already `processing` when the
  sheet opens is restored from the session at once, without waiting for the payment methods' setup.
- The card providers' confirmation steps (code, PIN, phone, date of birth, billing address) and the
  sandbox 3-D Secure email code, each with its own screen, resend countdown and remaining attempts.
- The payment's status is followed in real time over Pusher, Reverb or Soketi (`PresentOptions.realtime`
  points it at another host) with polling next to it, and settles every outcome: paid, declined
  with nothing charged, failed, cancelled on the phone, expired.
- Requests carry the device signals Wajub's fraud checks expect, a stable install fingerprint that
  is never derived from a hardware identifier, an `Idempotency-Key` that automatic retries reuse,
  and per-call timeouts (10 s to connect, where the connection can be seen). A payment whose answer
  never arrived (or a server error) is shown as in progress, never as a failure; the watch ends after 15
  minutes of the phone's monotonic time, whatever its clock says; if it still has not started 60 s later,
  the sheet goes back to the form and the next Pay reuses the same `Idempotency-Key`, so nothing is
  charged twice. Each submission sends a fresh Altcha solution when the payment asks for one.
- `PresentOptions.appearance` takes Wajub.js's appearance object (presets, variables, light, dark
  or automatic scheme, your app's own theme with `inherit`), on top of the merchant's branding from
  the dashboard; the skeleton loader and `readyTimeout` with a Retry button. Wajub.js's `"none"` is
  `.noPreset` for `theme` and `.noShadow` for `shadow`, so neither can be mistaken for `nil`.
- A privacy manifest (`PrivacyInfo.xcprivacy`) for your app's privacy report: no tracking, the
  system boot time only to time the SDK's waits, and the data a payment sends to Wajub. The README's
  Privacy section lists what to declare in App Store Connect.
- `Checkout.present(_:presenter:browser:)` runs the checkout under your own UI: it hands the
  `CheckoutController` it creates to your `CheckoutPresenting`.
- Every text in English and French, following the payment's language unless `locale` says otherwise.
