import XCTest
@testable import WajubMobile

/// PR — lenient parsing of every API answer.
final class ParsingTests: XCTestCase {
    /// PR-01 parses every fixture
    func test_PR_01_parsesEveryFixture() throws {
        let names = Fixtures.allNames
        XCTAssertEqual(names.count, 99)
        for name in names {
            let envelope = Fixtures.envelope(name)
            let status = envelope["http_status"]?.int ?? 200
            let path = envelope["request"]?["path"]?.string
            let body = Fixtures.body(name)
            guard let path else {
                // A realtime event: its `data` is what a socket frame carries.
                XCTAssertNotNil(PaymentStatusUpdatedEvent(data: body), name)
                XCTAssertNotNil(PaymentStatusUpdatedEvent(data: .string(body.jsonString)), name)
                continue
            }
            if status >= 400 {
                let error = APIErrorBody(json: body)
                XCTAssertEqual(error.code ?? status, status, name)
                continue
            }
            switch path {
            case "/pay/session":
                let session = try SessionResponse(json: body)
                XCTAssertFalse(session.transaction.id.isEmpty, name)
            case "/pay/sdk-config":
                XCTAssertFalse(SdkConfigResponse(json: body).channels.isEmpty, name)
            case "/pay/status":
                XCTAssertNotEqual(StatusResponse(json: body).transaction.status.rawValue, "", name)
            case "/pay/cancel":
                XCTAssertNotNil(CancelResponse(json: body).redirectURL, name)
            case "/pay/broadcasting/auth":
                XCTAssertEqual(body["auth"]?.string, "wajub-app-key:SIGNATURE")
            case let path where path.hasSuffix("/verify") && !path.contains("3ds"):
                _ = StepVerifyResponse(json: body)
            case let path where path.hasSuffix("/resend") || path.hasSuffix("/3ds/send"):
                _ = ResendResponse(json: body)
            default:
                _ = ProcessResponse(json: body)
            }
        }
    }

    /// PR-02 ignores unknown keys
    func test_PR_02_ignoresUnknownKeys() throws {
        let original = Fixtures.body("session-cm-aggregate")
        var mutated = original.setting(["surprise"], to: ["nested": true])
        mutated = mutated.setting(["transaction", "surprise"], to: 1)
        mutated = mutated.setting(["branding", "surprise"], to: "x")
        mutated = mutated.setting(["channels", "0", "surprise"], to: [1, 2])
        mutated = mutated.setting(["channels", "1", "operators", "0", "surprise"], to: nil)
        mutated = mutated.setting(["channels", "1", "operators", "0", "another"], to: "y")
        XCTAssertEqual(try SessionResponse(json: mutated), try SessionResponse(json: original))
    }

    /// PR-03 accepts numbers as int, double or numeric string
    func test_PR_03_acceptsNumbersAsIntDoubleOrNumericString() throws {
        let body = Fixtures.body("session-payer-bears-fee")
        let session = try SessionResponse(json: body)
        XCTAssertEqual(session.transaction.amount, 10000)
        XCTAssertEqual(session.transaction.amountTotal, 10350)
        XCTAssertEqual(session.transaction.fee?.rate, 0.035)
        for encoding: JSONValue in [25000, 25000.0, "25000", "25000.00"] {
            let parsed = try SessionResponse(json: body.setting(["transaction", "amount"], to: encoding))
            XCTAssertEqual(parsed.transaction.amount, 25000, "\(encoding)")
        }
        let rate = try SessionResponse(json: body.setting(["transaction", "fee", "rate"], to: "0.035"))
        XCTAssertEqual(rate.transaction.fee?.rate, 0.035)
        let minimum = try SessionResponse(json: body.setting(["channels", "1", "min_amount"], to: "abc"))
        XCTAssertNil(minimum.channels[1].minAmount)
        let maximum = try SessionResponse(json: body.setting(["channels", "1", "max_amount"], to: .null))
        XCTAssertNil(maximum.channels[1].maxAmount)
        XCTAssertThrowsError(try SessionResponse(json: body.setting(["transaction", "amount"], to: "abc")))
        XCTAssertThrowsError(try SessionResponse(json: body.setting(["transaction", "amount"], to: .null)))
    }

    /// PR-04 accepts booleans in every encoding
    func test_PR_04_acceptsBooleansInEveryEncoding() throws {
        let body = Fixtures.body("session-cm-aggregate")
        XCTAssertEqual(try SessionResponse(json: body).branding.isWhiteLabel, true)
        for truthy: JSONValue in [true, 1, "true", "1"] {
            XCTAssertTrue(try SessionResponse(json: body.setting(["branding", "white_label"], to: truthy)).branding.isWhiteLabel)
            XCTAssertTrue(try SessionResponse(json: body.setting(["transaction", "sandbox"], to: truthy)).transaction.sandbox)
        }
        for falsy: JSONValue in [false, 0, "false", "0"] {
            XCTAssertFalse(try SessionResponse(json: body.setting(["branding", "white_label"], to: falsy)).branding.isWhiteLabel)
            XCTAssertFalse(try SessionResponse(json: body.setting(["transaction", "sandbox"], to: falsy)).transaction.sandbox)
        }
    }

    /// PR-05 parses branding with mixed types
    func test_PR_05_parsesBrandingWithMixedTypes() throws {
        let branding = try SessionResponse(json: Fixtures.body("session-cm-aggregate")).branding
        XCTAssertTrue(branding.isWhiteLabel)
        XCTAssertEqual(branding.overlayIntensity, 40)
        XCTAssertEqual(branding.fontWeightHeading, 600)
        XCTAssertEqual(branding.fontWeightBody, 400, "an integer (2.1)")
        XCTAssertEqual(branding.borderRadius, "12px")
        XCTAssertEqual(branding.appearanceMode, "light")
        for older in ["session-saved-methods", "session-payer-bears-fee"] {
            let branding = try SessionResponse(json: Fixtures.body(older)).branding
            XCTAssertEqual(branding.fontWeightHeading, 600, older)
            XCTAssertEqual(branding.fontWeightBody, 400, "\(older): a numeric string (2.0)")
        }

        let plain = try SessionResponse(json: Fixtures.body("session-ci-xof-wallets")).branding
        XCTAssertFalse(plain.isWhiteLabel)
        XCTAssertNil(plain.primaryColor)
        XCTAssertNil(plain.fontWeightHeading)
        XCTAssertNil(plain.appearanceMode)

        let object = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(
            ["branding", "white_label"], to: ["enabled": true, "brand_name": "Akwa Pay", "support_email": nil]))
        XCTAssertEqual(object.branding.whiteLabel?.enabled, true)
        XCTAssertEqual(object.branding.whiteLabel?.brandName, "Akwa Pay")

        let empty = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding"], to: [:]))
        XCTAssertNil(empty.branding.primaryColor)
        XCTAssertFalse(empty.branding.isWhiteLabel)
        let missing = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding"], to: nil))
        XCTAssertNil(missing.branding.businessName)
    }

    /// PR-06 reads dotted keys literally
    func test_PR_06_readsDottedKeysLiterally() throws {
        let session = try SessionResponse(json: Fixtures.body("session-cm-aggregate"))
        XCTAssertEqual(session.channels[0].nameFr, "Carte bancaire")
        XCTAssertEqual(session.branding.cardBackgroundColor, "#FFFFFF")
        XCTAssertEqual(session.branding.cardBorderColor, "#E5E7EB")
        let sandbox = try SessionResponse(json: Fixtures.body("session-sandbox-cm"))
        XCTAssertEqual(sandbox.channels[0].name, "Card")
        XCTAssertEqual(sandbox.channels[0].nameFr, "Carte bancaire")
    }

    /// PR-07 accepts null optionals
    func test_PR_07_acceptsNullOptionals() throws {
        let session = try SessionResponse(json: Fixtures.body("session-ci-xof-wallets"))
        XCTAssertNil(session.transaction.customer)
        XCTAssertNil(session.transaction.fee)
        XCTAssertNil(session.transaction.receiptURL)
        XCTAssertNil(session.locale)
        XCTAssertNil(session.channels.first { $0.slug == "ci.moov" }?.logo)
        XCTAssertNil(session.channels[0].minAmount)
        XCTAssertNil(session.altcha)
        let sandbox = try SessionResponse(json: Fixtures.body("session-sandbox-cm"))
        XCTAssertNil(sandbox.branding.primaryColor)
        XCTAssertNil(sandbox.transaction.errorCode, "error_code: null")
        XCTAssertNil(sandbox.channels[0].logoPNG, "logo_png: null")
        let older = try SessionResponse(json: Fixtures.body("session-processing-mobile-money"))
        XCTAssertNotNil(older.echo)
        XCTAssertNil(older.echo?.key, "key: null")
    }

    /// PR-08 accepts absent optional objects
    func test_PR_08_acceptsAbsentOptionalObjects() throws {
        let session = try SessionResponse(json: Fixtures.body("session-cm-aggregate"))
        XCTAssertNil(session.transaction.processingContext)
        XCTAssertNil(session.savedMethods)
        XCTAssertNotNil(session.echo)
        XCTAssertNil(try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["echo"], to: nil)).echo)
        XCTAssertEqual(try SessionResponse(json: Fixtures.body("session-saved-methods")).savedMethods?.count, 2)

        let sandbox = Fixtures.config("sdk-config-sandbox")
        XCTAssertEqual(sandbox.channels["card"]?.clientSession, false)
        XCTAssertEqual(sandbox.channels["card"]?.sdk, "form")

        let process = ProcessResponse(json: Fixtures.body("process-processing-mobile-money-sandbox"))
        XCTAssertNil(process.action)
        XCTAssertNil(process.clientSession)
        XCTAssertNotNil(process.transaction?.processingContext)
    }
}
