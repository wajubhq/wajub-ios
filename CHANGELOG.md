# Changelog

## 1.1.0 (unreleased)

- Card payments whose provider asks for several confirmation steps in a row (a date of birth then a
  code, a PIN then the bank's page) go through each step in the sheet.
- Channel and operator logos show as images where Wajub has them; the others keep their brand badge.
  For your own screens, `CheckoutMethod.drawableLogo` and `OperatorChoice.drawableLogoURL` give the
  logo iOS can draw; `logo` and `logoURL` are unchanged.
- `WajubSession.verifyStep(_:id:fields:)` answers a confirmation step and says what follows it,
  another step included, for apps that draw their own screens.
- Mobile Money numbers are read by each country's current numbering plan: the leading 0 is kept
  where it is part of the number (Côte d'Ivoire, Benin, Congo, Burkina Faso), a number from an
  earlier plan is read in its current form (Benin's 8-digit numbers, Gabon's), and the operator is
  recognised from the number in more countries.
- In a sandbox payment, Wajub's Mobile Money test numbers are accepted, paid through the operator
  they test, and sent as typed. `MobileMoneyData.sandboxTestNumber(_:country:)` and the `sandbox:`
  variants of `isValid`, `detectOperator` and `e164` do the same for your own screens.
- `PresentOptions.realtime` and `RealtimeOptions` are deprecated: the payment's live updates need no
  setting. Code that sets them still compiles and behaves as before; remove them, as they will go
  in a later major version.

## 1.0.0 — 2026-10-15

- First release: a Swift package for iOS 15 and later with two products, `WajubMobileUI` (the
  SwiftUI payment sheet) and `WajubMobile` (the models, the errors, the Mobile Money helpers and
  the checkout's logic for your own screens).
- `WajubCheckout.present(_:from:)` presents the sheet and resolves once, when the sheet is gone,
  with `complete`, `processing`, `failed` or `cancelled`. Presenting a second sheet while one is
  open throws `sheet_already_presented`; one presented from `onComplete` waits for the closing
  sheet. A sheet whose presenting screen goes away resolves (`host_gone`) and never cancels the
  payment.
- Mobile Money: the country, the number formatted as you type, the operator picker with logos or
  brand badges, the operator found from the number, a clear message when the number belongs to
  another operator, and an approval screen while the payer confirms on the phone.
- Cards: the provider's secure page in Safari, the sandbox test card form, and Stripe through a
  `CardCollector` you build with Stripe's SDK. One-tap wallets open the wallet's own app.
- The card confirmation steps (code, PIN, phone, date of birth, billing address) and 3-D Secure,
  each with its own screen, attempts left and a new code on request.
- Closing the sheet before any attempt cancels the payment, unless `cancelOnDismiss` is `false`.
  Closing it while a payment is under way resolves `processing` and never cancels; closing it on a
  failure resolves `failed` with the error the payer saw. **Cancel payment** is offered on the
  methods, the form and a failure the payer can retry.
- A payment whose outcome is not known yet shows "Payment in progress", never a failure.
- `appearance`: presets, variables, a light, dark or automatic scheme and your app's own theme,
  over the merchant's branding. The `"none"` preset is `.noPreset`, and no shadow is `.noShadow`.
- A privacy manifest for your app's privacy report.
- `Checkout.present(_:presenter:browser:)` runs the checkout under your own UI.
- Every text in English and French, following the payment's language unless `locale` says
  otherwise.
