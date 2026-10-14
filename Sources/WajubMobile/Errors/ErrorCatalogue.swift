import Foundation

/// One code of errors.md §3: its type, whether the payer can try again, and its texts.
struct CatalogueEntry: Sendable {
    let type: WajubErrorType
    let retryable: Bool
    let en: String
    let fr: String

    func message(_ language: WajubLanguage) -> String { language == .fr ? fr : en }
}

/// errors.md §3, the web checkout's texts where it has one.
enum ErrorCatalogue {
    typealias E = CatalogueEntry

    /// The text for a `402` whose `error_code` is a PSP code the catalogue does not list (`failed`, `stolen_card`, …).
    static let genericDecline = E(type: .paymentError, retryable: true,
                                  en: "This payment could not be completed. Try again or use another payment method.",
                                  fr: "Ce paiement n'a pas abouti. Réessayez ou utilisez un autre moyen de paiement.")

    static let entries: [String: CatalogueEntry] = [
        // Load
        "session_not_found": E(type: .authenticationError, retryable: false,
                               en: "We couldn't find this payment session. Check the link you received or ask the merchant for a new one.",
                               fr: "Nous n'avons pas pu retrouver cette session de paiement. Vérifiez le lien reçu ou demandez-en un nouveau au marchand."),
        "session_terminal_expired": E(type: .invalidRequestError, retryable: false,
                                      en: "This payment session has expired.", fr: "Cette session de paiement a expiré."),
        "session_terminal_cancelled": E(type: .invalidRequestError, retryable: false,
                                        en: "This payment was cancelled.", fr: "Ce paiement a été annulé."),
        "session_terminal_failed": E(type: .invalidRequestError, retryable: false,
                                     en: "This payment has ended without being paid. Ask the merchant for a new payment link.",
                                     fr: "Ce paiement s'est terminé sans être réglé. Demandez un nouveau lien de paiement au marchand."),
        "load_error": E(type: .apiError, retryable: true,
                        en: "We couldn't load the payment. Check your connection and try again.",
                        fr: "Impossible de charger le paiement. Vérifiez votre connexion et réessayez."),
        "ready_timeout": E(type: .apiError, retryable: true,
                           en: "We couldn't load the payment. Check your connection and try again.",
                           fr: "Impossible de charger le paiement. Vérifiez votre connexion et réessayez."),
        "no_payment_method": E(type: .invalidRequestError, retryable: false,
                               en: "No payment method is available for this payment.",
                               fr: "Aucun moyen de paiement n'est disponible pour ce paiement."),
        // Transport
        "network_error": E(type: .apiError, retryable: true,
                           en: "Connection error. Check your network.", fr: "Erreur de connexion. Vérifiez votre réseau."),
        "timeout": E(type: .apiError, retryable: true,
                     en: "The request timed out.", fr: "Le délai d'attente a été dépassé."),
        "server_error": E(type: .apiError, retryable: true,
                          en: "Service temporarily unavailable.", fr: "Service temporairement indisponible."),
        "rate_limited": E(type: .rateLimitError, retryable: true,
                          en: "Too many attempts. Please wait {seconds} s before trying again.",
                          fr: "Trop de tentatives. Merci de patienter {seconds} s avant de réessayer."),
        "request_failed": E(type: .invalidRequestError, retryable: false,
                            en: "An error occurred. Please try again.", fr: "Une erreur est survenue. Veuillez réessayer."),
        // Form
        "phone_required": E(type: .invalidRequestError, retryable: true,
                            en: "Enter the Mobile Money number to pay with.", fr: "Saisissez le numéro Mobile Money qui va payer."),
        "invalid_phone": E(type: .invalidRequestError, retryable: true,
                           en: "Invalid phone number", fr: "Numéro de téléphone invalide"),
        "operator_mismatch": E(type: .invalidRequestError, retryable: true,
                               en: "This is a {detected} number. Pick {detected} in the list, or enter a {selected} number.",
                               fr: "Ce numéro est un numéro {detected}. Choisissez {detected} dans la liste, ou saisissez un numéro {selected}."),
        "operator_required": E(type: .invalidRequestError, retryable: true,
                               en: "Choose your Mobile Money operator.", fr: "Choisissez votre opérateur Mobile Money."),
        "operator_unavailable": E(type: .invalidRequestError, retryable: true,
                                  en: "No Mobile Money operator is available for this country. Try another payment method.",
                                  fr: "Aucun opérateur Mobile Money n'est disponible pour ce pays. Essayez un autre moyen de paiement."),
        "field_required": E(type: .invalidRequestError, retryable: true,
                            en: "This field is required", fr: "Ce champ est requis"),
        "invalid_email": E(type: .invalidRequestError, retryable: true,
                           en: "Enter a valid email address.", fr: "Saisissez une adresse e-mail valide."),
        "validation_error": E(type: .invalidRequestError, retryable: true,
                              en: "Check the information entered.", fr: "Vérifiez les informations saisies."),
        // Payment
        "payment_declined": E(type: .paymentError, retryable: true,
                              en: "Payment declined by the issuer.", fr: "Paiement refusé par l'émetteur."),
        "insufficient_funds": E(type: .paymentError, retryable: true,
                                en: "Insufficient funds.", fr: "Fonds insuffisants."),
        "merchant_not_verified": E(type: .paymentError, retryable: false,
                                   en: "This merchant can't accept payments yet. Please contact them.",
                                   fr: "Ce marchand ne peut pas encore accepter de paiements. Veuillez le contacter."),
        "limit_exceeded": E(type: .paymentError, retryable: true,
                            en: "This payment exceeds this merchant's allowed limit. Try a smaller amount or contact the merchant.",
                            fr: "Ce paiement dépasse la limite autorisée pour ce marchand. Essayez un montant plus faible ou contactez le marchand."),
        "shield_blocked": E(type: .paymentError, retryable: false,
                            en: "Payment blocked for security. Reference: {block_reference}.",
                            fr: "Paiement bloqué pour sécurité. Référence : {block_reference}."),
        "merchant_restricted": E(type: .paymentError, retryable: false,
                                 en: "Payments are currently restricted for this merchant.",
                                 fr: "Les paiements sont actuellement restreints pour ce marchand."),
        "payment_method_restricted": E(type: .paymentError, retryable: true,
                                       en: "This payment method is not available for this merchant.",
                                       fr: "Ce moyen de paiement n'est pas disponible pour ce marchand."),
        "country_restricted": E(type: .paymentError, retryable: false,
                                en: "This merchant does not accept payments from your country.",
                                fr: "Ce marchand n'accepte pas les paiements depuis votre pays."),
        "currency_restricted": E(type: .paymentError, retryable: false,
                                 en: "This merchant does not accept payments in this currency.",
                                 fr: "Ce marchand n'accepte pas les paiements dans cette devise."),
        "channel_not_accepted": E(type: .paymentError, retryable: true,
                                  en: "This payment method is not available for this payment.",
                                  fr: "Ce moyen de paiement n'est pas disponible pour ce paiement."),
        "payment_failed": E(type: .paymentError, retryable: false,
                            en: "Your payment could not be processed.", fr: "Votre paiement n'a pas pu être traité."),
        "payment_attempt_ended": E(type: .paymentError, retryable: true,
                                   en: "Your payment was not completed, and nothing was charged. Choose a payment method to try again.",
                                   fr: "Votre paiement n'a pas abouti et rien n'a été débité. Choisissez un moyen de paiement pour réessayer."),
        "payment_cancelled": E(type: .paymentError, retryable: false,
                               en: "This payment was cancelled.", fr: "Ce paiement a été annulé."),
        "session_expired": E(type: .invalidRequestError, retryable: false,
                             en: "This payment has expired.", fr: "Ce paiement a expiré."),
        "not_processable": E(type: .invalidRequestError, retryable: false,
                             en: "This payment can no longer be processed.", fr: "Ce paiement ne peut plus être traité."),
        "order_not_validated": E(type: .invalidRequestError, retryable: false,
                                 en: "The merchant has not confirmed this order yet. Try again in a moment.",
                                 fr: "Le marchand n'a pas encore confirmé cette commande. Réessayez dans un instant."),
        "raw_card_data_not_accepted": E(type: .invalidRequestError, retryable: false,
                                        en: "This payment method can't be used here.",
                                        fr: "Ce moyen de paiement ne peut pas être utilisé ici."),
        "security_check_failed": E(type: .invalidRequestError, retryable: true,
                                   en: "The security check failed. Try again in a moment.",
                                   fr: "La vérification de sécurité a échoué. Réessayez dans un instant."),
        "unsupported_action": E(type: .apiError, retryable: false,
                                en: "This payment step isn't supported in the app. Try another payment method.",
                                fr: "Cette étape de paiement n'est pas prise en charge dans l'application. Essayez un autre moyen de paiement."),
        "redirect_unavailable": E(type: .apiError, retryable: true,
                                  en: "We couldn't open the payment page. Check that a web browser is enabled, then try again.",
                                  fr: "Impossible d'ouvrir la page de paiement. Vérifiez qu'un navigateur est activé, puis réessayez."),
        // Confirmation steps
        "invalid_otp": E(type: .invalidRequestError, retryable: true,
                         en: "Incorrect code. {n} attempts left.", fr: "Code incorrect. Encore {n} essais."),
        "otp_expired": E(type: .invalidRequestError, retryable: true,
                         en: "The code has expired.", fr: "Le code a expiré."),
        "invalid_pin": E(type: .invalidRequestError, retryable: true,
                         en: "Incorrect PIN. {n} attempts left.", fr: "Code PIN incorrect. Encore {n} essais."),
        "pin_expired": E(type: .invalidRequestError, retryable: true,
                         en: "This verification has expired.", fr: "Cette vérification a expiré."),
        "phone_expired": E(type: .invalidRequestError, retryable: true,
                           en: "This verification has expired.", fr: "Cette vérification a expiré."),
        "invalid_birthday": E(type: .invalidRequestError, retryable: true,
                              en: "This date of birth was not accepted. {n} attempts left.",
                              fr: "Cette date de naissance n'a pas été acceptée. Encore {n} essais."),
        "birthday_expired": E(type: .invalidRequestError, retryable: true,
                              en: "This verification has expired.", fr: "Cette vérification a expiré."),
        "invalid_address": E(type: .invalidRequestError, retryable: true,
                             en: "This address was not accepted. {n} attempts left.",
                             fr: "Cette adresse n'a pas été acceptée. Encore {n} essais."),
        "address_expired": E(type: .invalidRequestError, retryable: true,
                             en: "This verification has expired.", fr: "Cette vérification a expiré."),
        "max_attempts_exceeded": E(type: .paymentError, retryable: true,
                                   en: "Too many incorrect attempts.", fr: "Trop de tentatives incorrectes."),
        "invalid_code": E(type: .invalidRequestError, retryable: true,
                          en: "Invalid verification code.", fr: "Code de vérification invalide."),
        "3ds_failed": E(type: .paymentError, retryable: true,
                        en: "3D Secure verification failed.", fr: "La vérification 3D Secure a échoué."),
        "3ds_rejected": E(type: .paymentError, retryable: true,
                          en: "Your bank declined the payment during 3D Secure.",
                          fr: "Votre banque a refusé le paiement lors du 3D Secure."),
        "3ds_cancelled": E(type: .paymentError, retryable: true,
                           en: "3D Secure verification was cancelled.", fr: "La vérification 3D Secure a été annulée."),
        "3ds_timeout": E(type: .paymentError, retryable: true,
                         en: "3D Secure verification has expired.", fr: "La vérification 3D Secure a expiré."),
        // Client sessions
        "client_session_unavailable": E(type: .invalidRequestError, retryable: false,
                                        en: "Card payment is not available in test mode for this provider.",
                                        fr: "Le paiement par carte n'est pas disponible en mode test pour ce prestataire."),
        "client_session_expired": E(type: .invalidRequestError, retryable: true,
                                    en: "This card payment session has expired. Start again.",
                                    fr: "Cette session de paiement par carte a expiré. Recommencez."),
        // SDK use (developer-facing, English)
        "sheet_already_presented": E(type: .invalidRequestError, retryable: false,
                                     en: "A Wajub payment sheet is already presented.",
                                     fr: "A Wajub payment sheet is already presented."),
    ]
}

/// Where an answer was received: a `403` without a code means "not a payment session" while
/// loading and a merchant restriction afterwards.
enum ErrorPhase: Sendable {
    case loading
    case payment
}

extension WajubError {
    /// A catalogue error, `{…}` placeholders filled from `values`.
    static func catalogue(_ code: String, _ language: WajubLanguage, values: [String: String] = [:],
                          httpStatus: Int? = nil) -> WajubError {
        let entry = ErrorCatalogue.entries[code] ?? ErrorCatalogue.entries[Code.requestFailed]!
        return WajubError(type: entry.type, code: code, message: fill(entry.message(language), values),
                          retryable: entry.retryable, httpStatus: httpStatus)
    }

    static func network(_ language: WajubLanguage) -> WajubError { catalogue(Code.networkError, language) }

    static func timedOut(_ language: WajubLanguage) -> WajubError { catalogue(Code.timeout, language) }

    /// `ready_timeout`, with Wajub.js's developer text in `apiMessage`.
    static func readyTimeout(after milliseconds: Int, _ language: WajubLanguage) -> WajubError {
        var error = catalogue(Code.readyTimeout, language)
        error.apiMessage = "Payment sheet not ready after \(milliseconds) ms"
        return error
    }

    /// A failure answered HTTP 200 by a confirmation step (`{status: "failed", error: {code}}`).
    static func stepFailure(code: String, apiMessage: String?, attemptsRemaining: Int?, _ language: WajubLanguage) -> WajubError {
        var error: WajubError
        if ErrorCatalogue.entries[code] != nil {
            error = catalogue(code, language, values: ["n": String(attemptsRemaining ?? 0)])
        } else {
            error = WajubError(type: .invalidRequestError, code: code,
                               message: language == .en ? (apiMessage ?? ErrorCatalogue.entries[Code.validationError]!.en)
                                   : ErrorCatalogue.entries[Code.validationError]!.fr,
                               retryable: true)
        }
        error.httpStatus = 200
        error.apiMessage = apiMessage
        return error
    }

    /// Builds the `WajubError` of an API answer (errors.md §2).
    static func from(_ answer: APIAnswer, phase: ErrorPhase, language: WajubLanguage) -> WajubError {
        let status = answer.status
        let body = answer.body.map(APIErrorBody.init(json:))

        var code: String
        if let errorCode = body?.errorCode {
            code = errorCode
        } else if let nested = body?.nestedError?.code {
            code = nested
        } else {
            switch status {
            case 400: code = Code.notProcessable
            case 401, 404: code = Code.sessionNotFound
            case 402: code = Code.paymentDeclined
            case 403: code = phase == .loading ? Code.sessionNotFound : Code.merchantRestricted
            case 409: code = Code.orderNotValidated
            case 410: code = Code.sessionTerminalExpired
            case 422: code = Code.validationError
            case 429: code = Code.rateLimited
            case 500...: code = Code.serverError
            default: code = Code.requestFailed
            }
        }
        if status == 410 { code = Code.sessionTerminalExpired }

        let retryAfter = body?.retryAfter ?? answer.header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let apiMessage = body?.nestedError?.message ?? body?.message
        let values = ["seconds": String(retryAfter ?? 0), "block_reference": body?.blockReference ?? "",
                      "n": String(body?.attemptsRemaining ?? 0)]

        let type: WajubErrorType
        let retryable: Bool
        let message: String
        if let entry = ErrorCatalogue.entries[code] {
            type = entry.type
            retryable = entry.retryable
            if code == Code.validationError, language == .en, let apiMessage {
                message = apiMessage
            } else {
                message = fill(entry.message(language), values)
            }
        } else {
            type = WajubError.type(forStatus: status)
            switch status {
            case 402, 422, 500...: retryable = true
            default: retryable = false
            }
            if status == 402 {
                message = ErrorCatalogue.genericDecline.message(language)
            } else if language == .en, let text = answer.body?["payer_message"]?.nonEmptyString ?? apiMessage {
                message = text
            } else {
                let fallback = status == 422 ? Code.validationError : Code.serverError
                message = ErrorCatalogue.entries[fallback]!.message(language)
            }
        }

        var details: [String: String]?
        if let errors = body?.errors, !errors.isEmpty {
            details = errors.compactMapValues { $0.first }
        }
        return WajubError(type: type, code: code, message: message,
                          declineCode: status == 402 ? body?.errorCode : nil,
                          retryable: retryable,
                          param: body?.errors.count == 1 ? body?.errors.keys.first : nil,
                          httpStatus: status,
                          correlationId: answer.header("X-Request-Id"),
                          retryAfterSeconds: retryAfter,
                          details: details,
                          blockReference: body?.blockReference,
                          apiMessage: apiMessage)
    }

    static func type(forStatus status: Int) -> WajubErrorType {
        switch status {
        case 402, 403: return .paymentError
        case 401, 404: return .authenticationError
        case 429: return .rateLimitError
        case 500...: return .apiError
        default: return .invalidRequestError
        }
    }
}
