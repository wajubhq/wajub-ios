import Foundation

/// The sheet's language: French or English.
public enum WajubLanguage: String, Sendable, CaseIterable {
    case en, fr

    /// `fr…` is French, anything else English.
    public init(tag: String) {
        self = tag.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("fr") ? .fr : .en
    }

    /// The first of `PresentOptions.locale`, the session's `locale`, the device's language, reduced to `fr` or `en`.
    public static func resolve(option: String?, session: String?, device: String?) -> WajubLanguage {
        for candidate in [option, session, device] {
            if let tag = candidate?.trimmingCharacters(in: .whitespaces), !tag.isEmpty {
                return WajubLanguage(tag: tag)
            }
        }
        return .en
    }
}

/// Fills `{name}` placeholders.
func fill(_ template: String, _ values: [String: String]) -> String {
    var text = template
    for (key, value) in values {
        text = text.replacingOccurrences(of: "{\(key)}", with: value)
    }
    return text
}

/// Every text the sheet shows, in English and French.
public struct WajubStrings: Sendable {
    public let language: WajubLanguage

    public init(_ language: WajubLanguage) {
        self.language = language
    }

    private func t(_ en: String, _ fr: String) -> String {
        language == .fr ? fr : en
    }

    /// The sheet's text for an error code, placeholders left as they are.
    public func errorMessage(_ code: String) -> String {
        (ErrorCatalogue.entries[code] ?? ErrorCatalogue.entries[WajubError.Code.requestFailed]!).message(language)
    }

    // Loading and load errors
    public var loading: String { t("Loading the payment…", "Chargement du paiement…") }
    public var loadErrorTitle: String { t("We couldn't load the payment", "Impossible de charger le paiement") }
    public var endedTitle: String { t("This payment has ended", "Ce paiement est terminé") }
    public var retry: String { t("Retry", "Réessayer") }
    public var close: String { t("Close", "Fermer") }

    // Header and footer
    public var securedByWajub: String { t("Secured by Wajub", "Sécurisé par Wajub") }
    public var testMode: String { t("Test mode", "Mode test") }
    public var feesIncluded: String { t("Fees included", "Frais inclus") }

    // Methods
    public var chooseMethod: String { t("Choose a payment method", "Choisissez un moyen de paiement") }
    public var otherMethods: String { t("Other payment methods", "Autres moyens de paiement") }
    public var mobileMoney: String { "Mobile Money" }
    public var card: String { t("Card", "Carte bancaire") }
    public func minimum(_ amount: String) -> String { fill(t("Minimum {amount}", "Minimum {amount}"), ["amount": amount]) }
    public func maximum(_ amount: String) -> String { fill(t("Maximum {amount}", "Maximum {amount}"), ["amount": amount]) }
    public var cancelPayment: String { t("Cancel payment", "Annuler le paiement") }
    public func pay(_ amount: String) -> String { fill(t("Pay {amount}", "Payer {amount}"), ["amount": amount]) }

    // Mobile Money form
    public var country: String { t("Country", "Pays") }
    public var mobileMoneyNumber: String { t("Mobile Money number", "Numéro Mobile Money") }
    public var mobileMoneyOperator: String { t("Operator", "Opérateur") }
    public var changeOperator: String { t("Change", "Modifier") }
    /// The number's operator cannot take this amount; `limit` is "Maximum …" or "Minimum …".
    public func operatorOutOfLimits(_ name: String, limit: String) -> String {
        fill(t("{name} can't be used for this amount ({limit}). Choose another operator or payment method.",
               "{name} ne peut pas être utilisé pour ce montant ({limit}). Choisissez un autre opérateur ou moyen de paiement."),
             ["name": name, "limit": limit])
    }

    // Card
    public var payByCard: String { t("Pay by card", "Payer par carte") }
    public var cardRedirectHint: String {
        t("You'll finish on your card provider's secure page.", "Vous terminerez sur la page sécurisée de votre prestataire de carte.")
    }
    public var cardNumber: String { t("Card number", "Numéro de carte") }
    public var cardHolder: String { t("Cardholder name", "Titulaire de la carte") }
    public var expiryMonth: String { t("Month (MM)", "Mois (MM)") }
    public var expiryYear: String { t("Year (YY)", "Année (AA)") }
    public var cvv: String { "CVV" }
    public var sandboxCardHint: String { t("Test mode: use one of Wajub's test cards.", "Mode test : utilisez une des cartes de test de Wajub.") }

    /// The label of a contact or billing field (`email`, `first_name`, …).
    public func fieldLabel(_ field: String) -> String {
        switch field {
        case "email": return t("Email", "E-mail")
        case "first_name": return t("First name", "Prénom")
        case "last_name": return t("Last name", "Nom")
        case "phone": return t("Phone number", "Numéro de téléphone")
        case "address": return t("Address", "Adresse")
        case "city": return t("City", "Ville")
        case "country": return t("Country (2-letter code)", "Pays (code à 2 lettres)")
        case "state": return t("State or region", "Région")
        case "zip_code": return t("ZIP or postal code", "Code postal")
        default: return field
        }
    }

    // Wallets
    public func payWith(_ name: String) -> String { fill(t("Pay with {name}", "Payer avec {name}"), ["name": name]) }
    public func walletHint(_ name: String) -> String {
        fill(t("You'll approve the payment in {name}.", "Vous validerez le paiement dans {name}."), ["name": name])
    }

    // Approval and USSD
    public var approvalTitle: String { t("Approve the payment on your phone", "Validez le paiement sur votre téléphone") }
    public func approvalBody(amount: String, phone: String?) -> String {
        if let phone {
            return fill(t("A request for {amount} was sent to {phone}.", "Une demande de {amount} a été envoyée au {phone}."),
                        ["amount": amount, "phone": phone])
        }
        return fill(t("A request for {amount} was sent to your phone.", "Une demande de {amount} a été envoyée sur votre téléphone."),
                    ["amount": amount])
    }
    public var instructions: String { "Instructions" }
    public var waitingForApproval: String { t("Waiting for your approval…", "En attente de votre validation…") }
    public var ussdTitle: String { t("Dial this code to pay", "Composez ce code pour payer") }

    // Pending
    public var pendingTitle: String { t("Payment in progress", "Paiement en cours") }
    public var pendingBody: String { t("We're waiting for the confirmation of your payment.", "Nous attendons la confirmation de votre paiement.") }
    public var pendingCapBody: String {
        t("Payment in progress — you will be notified.", "Paiement en cours — vous serez notifié.")
    }
    public var browserBody: String {
        t("Finish the payment in the page that opened, then come back here.", "Terminez le paiement dans la page qui s'est ouverte, puis revenez ici.")
    }
    public var continuePayment: String { t("Continue payment", "Continuer le paiement") }

    // Confirmation steps
    public func stepTitle(_ kind: ConfirmStepKind) -> String {
        switch kind {
        case .otp: return t("Enter the code you received", "Saisissez le code reçu")
        case .pin: return t("Enter your card PIN", "Saisissez le code PIN de votre carte")
        case .phone: return t("Confirm your phone number", "Confirmez votre numéro de téléphone")
        case .birthday: return t("Enter your date of birth", "Saisissez votre date de naissance")
        case .address: return t("Enter your billing address", "Saisissez votre adresse de facturation")
        }
    }
    public func codeSentTo(_ contact: String) -> String { fill(t("Sent to {contact}", "Envoyé au {contact}"), ["contact": contact]) }
    /// The OTP screen's line when the provider does not say where the code went.
    public var codeSent: String { t("A code was sent to you.", "Un code vous a été envoyé.") }
    public var code: String { t("Code", "Code") }
    public var pin: String { t("PIN", "Code PIN") }
    public var birthday: String { t("Date of birth", "Date de naissance") }
    public var confirm: String { t("Confirm", "Confirmer") }
    public var resendCode: String { t("Resend code", "Renvoyer le code") }
    public func resendIn(_ seconds: Int) -> String { fill(t("Resend in {seconds} s", "Renvoyer dans {seconds} s"), ["seconds": String(seconds)]) }
    public var threeDSTitle: String { t("Enter the verification code", "Saisissez le code de vérification") }
    public func threeDSCodeSent(_ email: String) -> String {
        fill(t("A code was sent to {email}.", "Un code a été envoyé à {email}."), ["email": email])
    }
    public func expiresIn(_ time: String) -> String { fill(t("Expires in {time}", "Expire dans {time}"), ["time": time]) }
    public var threeDSBrowserTitle: String { t("Complete 3-D Secure", "Terminez le 3-D Secure") }

    // Outcomes
    public var successTitle: String { t("Payment successful", "Paiement réussi") }
    public func paidTo(amount: String, merchant: String?) -> String {
        guard let merchant else { return fill(t("{amount} paid", "{amount} payés"), ["amount": amount]) }
        return fill(t("{amount} paid to {merchant}", "{amount} payés à {merchant}"), ["amount": amount, "merchant": merchant])
    }
    public var reference: String { t("Reference", "Référence") }
    public var viewReceipt: String { t("View receipt", "Voir le reçu") }
    public var failedTitle: String { t("Payment failed", "Paiement échoué") }
    public var expiredTitle: String { t("This payment has expired", "Ce paiement a expiré") }
    public var cancelledTitle: String { t("Payment cancelled", "Paiement annulé") }
    public var tryAgain: String { t("Try again", "Réessayer") }
    public func tryAgainIn(_ seconds: Int) -> String { fill(t("Try again in {seconds} s", "Réessayer dans {seconds} s"), ["seconds": String(seconds)]) }

    // The code the payer generates in the operator's menu
    public var payerOTPTitle: String { t("Generate your payment code", "Générez votre code de paiement") }
    public var payerOTPDescription: String {
        t("Before you pay, your operator asks for a code you generate yourself from its menu, for the exact amount of the payment.",
          "Avant de payer, votre opérateur demande un code que vous générez vous-même depuis son menu, pour le montant exact du paiement.")
    }
    public var payerOTPDial: String { t("Code to dial", "Code à composer") }
    public var copy: String { t("Copy", "Copier") }
    public var copied: String { t("Copied", "Copié") }
    public var payerOTPAmount: String { t("Exact amount to enter", "Montant exact à saisir") }
    public var payerOTPStepsTitle: String { t("How to get your code", "Comment obtenir votre code") }
    /// The steps shown when the operator gives none; `{amount}` is the exact amount.
    public var payerOTPGenericSteps: [String] {
        [t("Open your operator's Mobile Money menu (USSD code or app).",
           "Ouvrez le menu Mobile Money de votre opérateur (code USSD ou application)."),
         t("Generate a payment code for the exact amount: {amount}.",
           "Générez un code de paiement pour le montant exact : {amount}."),
         t("Enter the code you received below.", "Saisissez ci-dessous le code que vous avez reçu.")]
    }
    public var payerOTPCodeLabel: String { t("Payment code", "Code de paiement") }
    public var payerOTPSubmit: String { t("Confirm payment", "Valider le paiement") }
    public var payerOTPChangeMethod: String { t("Use another payment method", "Changer de moyen de paiement") }
    public func payerOTPSandboxHint(_ code: String) -> String {
        fill(t("Test mode: enter the code {code}. Any other code is refused.",
               "Mode test : saisissez le code {code}. Tout autre code est refusé."), ["code": code])
    }
    public var payerOTPApprovalMessage: String {
        t("Code received. Your operator is processing the payment, this can take a moment.",
          "Code reçu. Votre opérateur traite le paiement, cela peut prendre quelques instants.")
    }
    /// The Mobile Money form's line when the chosen operator will ask for the payer's code.
    public func payerOTPFormHint(ussdCode: String?) -> String {
        guard let ussdCode else {
            return t("For this payment, you will generate a code from your operator's menu: the next step guides you.",
                     "Pour ce paiement, vous générerez un code depuis le menu de votre opérateur : l'étape suivante vous guide.")
        }
        return fill(t("For this payment, you will generate a code by dialing {ussd_code}: the next step guides you.",
                      "Pour ce paiement, vous générerez un code en composant {ussd_code} : l'étape suivante vous guide."),
                    ["ussd_code": ussdCode])
    }
    public func payerOTPAttemptsRemaining(_ count: Int) -> String {
        switch count {
        case ...0: return t("No tries left.", "Plus aucun essai possible.")
        case 1: return t("1 try left.", "Il vous reste 1 essai.")
        default: return fill(t("{count} tries left.", "Il vous reste {count} essais."), ["count": String(count)])
        }
    }
    /// The code's expected length: exactly `length` digits, else `min` to `max`.
    public func payerOTPLength(_ length: Int?, min: Int = 4, max: Int = 8) -> String {
        if let length { return fill(t("The code must have {length} digits.", "Le code doit comporter {length} chiffres."), ["length": String(length)]) }
        return fill(t("The code must have between {min} and {max} digits.", "Le code doit comporter entre {min} et {max} chiffres."),
                    ["min": String(min), "max": String(max)])
    }
    public var payerOTPRefused: String {
        t("Your operator did not accept this code. Generate a new one and try again.",
          "Votre opérateur n'a pas accepté ce code. Générez-en un nouveau et réessayez.")
    }
}
