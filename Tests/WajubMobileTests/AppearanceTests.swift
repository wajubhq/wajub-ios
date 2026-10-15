import XCTest
@testable import WajubMobile

/// AP — the appearance object, token precedence, schemes, branding and presets.
final class AppearanceTests: XCTestCase {
    private let merchant = Fixtures.session("session-cm-aggregate").branding
    private let plain = Fixtures.session("session-ci-xof-wallets").branding

    /// AP-01 parses the appearance object
    func test_AP_01_parsesTheAppearanceObject() throws {
        let json = try JSONValue.parse("""
        {"theme": "night", "colorScheme": "light", "inherit": true, "labels": "floating", "shadow": "high", "disableAnimations": true,
         "primaryColor": "#ff0000", "secondaryColor": "#00ff00", "backgroundColor": "#0000ff", "fontFamily": "Inter, sans-serif",
         "borderRadius": "6px", "buttonTextColor": "#111111", "inputBackgroundColor": "#222222", "inputBorderColor": "#333333",
         "textMutedColor": "#444444", "successColor": "#555555", "errorColor": "#666666",
         "variables": {"colorPrimary": "#123456", "colorBackground": "#fafafa", "colorText": "#101010", "colorTextSecondary": "#202020",
                       "colorTextPlaceholder": "#303030", "colorDanger": "#404040", "colorSuccess": "#505050", "fontFamily": "Poppins",
                       "fontSizeBase": "17px", "fontWeightNormal": "400", "fontWeightMedium": "500", "fontWeightBold": "bold",
                       "spacingUnit": "5", "borderRadius": "0.5rem", "spacingGridRow": "14px", "spacingGridColumn": "10px", "unknown": "x"},
         "rules": {".Input": {"color": "red"}}, "somethingElse": 1}
        """)
        let appearance = Appearance(json: json)
        XCTAssertEqual(appearance.theme, .night)
        XCTAssertEqual(appearance.colorScheme, .light)
        XCTAssertEqual(appearance.inherit, true)
        XCTAssertEqual(appearance.labels, .floating)
        XCTAssertEqual(appearance.shadow, .high)
        XCTAssertEqual(appearance.disableAnimations, true)
        XCTAssertEqual(appearance.primaryColor, "#ff0000")
        XCTAssertEqual(appearance.errorColor, "#666666")
        XCTAssertEqual(appearance.variables.colorPrimary, "#123456")
        XCTAssertEqual(appearance.variables.spacingGridColumn, "10px")
        XCTAssertEqual(appearance.variables.fontWeightBold, "bold")

        let theme = ThemeResolver.resolve(appearance: appearance, branding: nil, system: .dark)
        XCTAssertEqual(theme.shape.radius, 8, "0.5rem")
        XCTAssertEqual(theme.shape.fontWeightBold, 700)
        XCTAssertEqual(theme.shape.fontSizeBase, 17)
        XCTAssertEqual(theme.shape.spacingUnit, 5)
        XCTAssertEqual(theme.shape.gapRow, 14)
        XCTAssertEqual(theme.shape.fontFamilies, ["Poppins"])
        XCTAssertEqual(theme.tokens.text.hex, "#101010")

        // Wajub.js's "none" reads as the cases named so they can't pass for Optional.none.
        let none = Appearance(json: ["theme": "none", "shadow": "none"])
        XCTAssertEqual(none.theme, .noPreset)
        XCTAssertEqual(none.shadow, .noShadow)
        XCTAssertEqual(AppearanceTheme.noPreset.rawValue, "none")
        XCTAssertEqual(AppearanceShadow.noShadow.rawValue, "none")

        // Values that do not parse are ignored, never an error.
        let junk = Appearance(json: ["theme": "neon", "colorScheme": "sepia", "shadow": "huge", "labels": "inside",
                                     "primaryColor": "red", "borderRadius": "-4px",
                                     "variables": ["colorPrimary": "oklch(0.7 0.1 200)", "fontSizeBase": "big", "fontWeightBold": "heavy"]])
        XCTAssertNil(junk.theme)
        XCTAssertNil(junk.colorScheme)
        XCTAssertNil(junk.shadow)
        XCTAssertNil(junk.labels)
        let resolved = ThemeResolver.resolve(appearance: junk, branding: nil, system: .light)
        XCTAssertEqual(resolved.tokens, ThemeTokens.defaults(.light))
        XCTAssertEqual(resolved.shape.radius, 8)
        XCTAssertEqual(resolved.shape.fontSizeBase, 16)
        XCTAssertEqual(resolved.shape.fontWeightBold, 600)

        XCTAssertEqual(RGBAColor(css: "#abc"), RGBAColor(css: "#AABBCC"))
        XCTAssertEqual(RGBAColor(css: "rgba(255, 0, 0, 0.5)")?.alpha, 0.5)
        XCTAssertEqual(RGBAColor(css: "rgb(255,255,255)"), RGBAColor(css: "#ffffff"))
        XCTAssertEqual(RGBAColor(css: "#11223380")?.hex, "#11223380")
        for invalid in ["red", "#12", "#12345", "rgb(1,2)", "rgb(300,0,0)", "hsl(0, 0%, 0%)"] {
            XCTAssertNil(RGBAColor(css: invalid), invalid)
        }
    }

    /// AP-02 resolves token precedence
    func test_AP_02_resolvesTokenPrecedence() {
        let inherited = InheritedTheme(primary: RGBAColor(css: "#7C2D12"))
        func primary(_ appearance: Appearance) -> String {
            ThemeResolver.resolve(appearance: appearance, branding: merchant, inherited: inherited, system: .light).tokens.primary.hex
        }
        var appearance = Appearance(theme: .stripe, inherit: true, variables: AppearanceVariables(colorPrimary: "#111827"),
                                    primaryColor: "#6D28D9")
        XCTAssertEqual(primary(appearance), "#111827", "variables")
        appearance.variables.colorPrimary = nil
        XCTAssertEqual(primary(appearance), "#6D28D9", "legacy key")
        appearance.primaryColor = nil
        XCTAssertEqual(primary(appearance), "#0570DE", "preset")
        appearance.theme = nil
        XCTAssertEqual(primary(appearance), "#7C2D12", "inherited")
        appearance.inherit = false
        XCTAssertEqual(primary(appearance), "#0F766E", "merchant branding")
        XCTAssertEqual(ThemeResolver.resolve(appearance: appearance, branding: plain, system: .light).tokens.primary.hex,
                       "#2563EB", "default palette")
    }

    /// AP-03 resolves the colour scheme
    func test_AP_03_resolvesTheColourScheme() {
        func scheme(_ appearance: Appearance?, _ branding: Branding?, inherited: InheritedTheme? = nil, system: ColorSchemeKind) -> ColorSchemeKind {
            ThemeResolver.resolve(appearance: appearance, branding: branding, inherited: inherited, system: system).scheme
        }
        XCTAssertEqual(scheme(Appearance(theme: .light, colorScheme: .dark), merchant, system: .light), .dark, "colorScheme first")
        XCTAssertEqual(scheme(Appearance(theme: .dark), merchant, system: .light), .dark, "theme names a scheme")
        XCTAssertEqual(scheme(Appearance(theme: .night), nil, system: .light), .dark, "the night preset")
        XCTAssertEqual(scheme(Appearance(inherit: true), merchant, inherited: InheritedTheme(scheme: .dark), system: .light), .dark,
                       "inherited before branding")
        XCTAssertEqual(scheme(nil, merchant, system: .dark), .light, "branding.appearance_mode: light")
        XCTAssertEqual(scheme(nil, plain, system: .dark), .dark, "auto follows the OS")
        XCTAssertEqual(scheme(nil, plain, system: .light), .light)
        XCTAssertEqual(scheme(Appearance(theme: .system), merchant, system: .dark), .dark, "system = auto")
        XCTAssertTrue(ThemeResolver.resolve(appearance: nil, branding: plain, system: .light).followsSystem)
        XCTAssertFalse(ThemeResolver.resolve(appearance: nil, branding: merchant, system: .light).followsSystem)
    }

    /// AP-04 uses the default palettes
    func test_AP_04_usesTheDefaultPalettes() {
        let light = ThemeResolver.resolve(appearance: nil, branding: plain, system: .light)
        let dark = ThemeResolver.resolve(appearance: nil, branding: plain, system: .dark)
        XCTAssertEqual(light.tokens, ThemeTokens.defaults(.light))
        XCTAssertEqual(dark.tokens, ThemeTokens.defaults(.dark))
        let expectedLight = ["#2563EB", "#1D4ED8", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#F5F5F5", "#EFF6FF", "#171717", "#525252", "#737373",
                             "#A3A3A3", "#2563EB", "#FFFFFF", "#E5E5E5", "#D4D4D4", "#3B82F6", "#B91C1C", "#EF4444", "#FEF2F2", "#15803D",
                             "#F0FDF4", "#B45309", "#FFFBEB", "#F5F5F5"]
        let expectedDark = ["#3B82F6", "#60A5FA", "#0A0A0A", "#0A0A0A", "#171717", "#262626", "#172554", "#FAFAFA", "#A3A3A3", "#8A8A8A",
                            "#525252", "#60A5FA", "#0A0A0A", "#404040", "#525252", "#60A5FA", "#F87171", "#F87171", "#450A0A", "#4ADE80",
                            "#052E16", "#FBBF24", "#451A03", "#262626"]
        XCTAssertEqual(hexes(light.tokens), expectedLight)
        XCTAssertEqual(hexes(dark.tokens), expectedDark)
        XCTAssertEqual(light.shape, ThemeShape(radius: 8, fontFamilies: ["Inter"], fontSizeBase: 16, fontWeightNormal: 400, fontWeightMedium: 500,
                                               fontWeightBold: 600, spacingUnit: 4, gapRow: 12, gapColumn: 12))
    }

    /// AP-05 applies merchant branding
    func test_AP_05_appliesMerchantBranding() throws {
        let theme = ThemeResolver.resolve(appearance: nil, branding: merchant, system: .light)
        XCTAssertEqual(theme.tokens.primary.hex, "#0F766E")
        XCTAssertEqual(theme.tokens.onPrimary.hex, "#FFFFFF")
        XCTAssertEqual(theme.tokens.surfaceMuted.hex, "#F0FDFA")
        XCTAssertEqual(theme.tokens.textSecondary.hex, "#6B7280")
        XCTAssertEqual(theme.tokens.inputBorder.hex, "#D1D5DB")
        XCTAssertEqual(theme.tokens.success.hex, "#16A34A")
        XCTAssertEqual(theme.tokens.danger.hex, "#DC2626")
        XCTAssertEqual(theme.shape.radius, 12)
        XCTAssertEqual(theme.shape.fontFamilies, ["Poppins"])
        XCTAssertEqual(theme.shape.fontWeightBold, 600)
        XCTAssertEqual(theme.shape.fontWeightNormal, 400)
        XCTAssertEqual(theme.shadow, .low)
        XCTAssertTrue(theme.hidesWajubBranding, "white_label: true")
        XCTAssertFalse(ThemeResolver.resolve(appearance: nil, branding: plain, system: .light).hidesWajubBranding)
        XCTAssertEqual(theme.logoURL, "https://cdn.shop.example.com/brand/logo.png")
        XCTAssertEqual(theme.businessName, "Boutique Akwa")
        XCTAssertEqual(theme.overlayOpacity, 0.4)

        // custom_css is never read.
        let css = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "custom_css"], to: "body{color:red}"))
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: css.branding, system: .light), theme)

        // A merchant primary under 3:1 against the background falls back to the default.
        let pale = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "primary_color"], to: "#FFFF66"))
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: pale.branding, system: .light).tokens.primary.hex, "#2563EB")

        // Scheme-bound colours stay on the scheme the merchant designed for.
        let darkTheme = ThemeResolver.resolve(appearance: Appearance(colorScheme: .dark), branding: merchant, system: .dark)
        XCTAssertEqual(darkTheme.tokens.background.hex, "#0A0A0A")
        XCTAssertEqual(darkTheme.tokens.surfaceMuted.hex, "#262626")
        XCTAssertEqual(darkTheme.tokens.primary.hex, "#0F766E")

        // The merchant's background, in the scheme it was designed for.
        let cream = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "background_color"], to: "#FFF7ED"))
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: cream.branding, system: .light).tokens.background.hex, "#FFF7ED")
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: cream.branding, system: .light).tokens.inputBackground.hex, "#FFFFFF",
                       "input_background_color")

        // Weights as words; the merchant's button text only with the merchant's primary.
        let words = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "font_weight_heading"], to: "bold")
            .setting(["branding", "font_weight_body"], to: "normal"))
        XCTAssertEqual(words.branding.fontWeightHeading, 700)
        XCTAssertEqual(words.branding.fontWeightBody, 400)
        let paleWithText = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "primary_color"], to: "#FFFF66")
            .setting(["branding", "button_text_color"], to: "#111111"))
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: paleWithText.branding, system: .light).tokens.onPrimary.hex, "#FFFFFF",
                       "computed for the default primary")

        // Merchant radius tokens.
        XCTAssertEqual(AppearanceValue.brandingRadius("lg"), 12)
        XCTAssertEqual(AppearanceValue.brandingRadius("none"), 0)
        XCTAssertEqual(AppearanceValue.brandingRadius("12"), 12)
        let wide = try SessionResponse(json: Fixtures.body("session-cm-aggregate").setting(["branding", "border_radius"], to: "40px"))
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: wide.branding, system: .light).shape.radius, 22, "capped")
    }

    /// AP-06 applies presets
    func test_AP_06_appliesPresets() {
        let stripe = Appearance.preset(.stripe)
        XCTAssertEqual(stripe?.primaryColor, "#0570de")
        XCTAssertEqual(stripe?.borderRadius, "4px")
        XCTAssertEqual(stripe?.fontFamily, "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif")
        XCTAssertEqual(stripe?.shadow, .low)
        let night = Appearance.preset(.night)
        XCTAssertEqual(night, Appearance(colorScheme: .dark, primaryColor: "#7c3aed", backgroundColor: "#0f172a", borderRadius: "8px",
                                         buttonTextColor: "#f8fafc", inputBackgroundColor: "#1e293b", inputBorderColor: "#334155",
                                         textMutedColor: "#94a3b8", shadow: .noShadow))
        XCTAssertEqual(Appearance.preset(.flat), Appearance(borderRadius: "0", shadow: .noShadow))
        XCTAssertEqual(Appearance.preset(.noPreset), Appearance())
        XCTAssertNil(Appearance.preset(.dark))

        let resolved = ThemeResolver.resolve(appearance: Appearance(theme: .night), branding: plain, system: .light)
        XCTAssertEqual(resolved.scheme, .dark)
        XCTAssertEqual(resolved.tokens.primary.hex, "#7C3AED")
        XCTAssertEqual(resolved.tokens.background.hex, "#0F172A")
        XCTAssertEqual(resolved.tokens.onPrimary.hex, "#F8FAFC")
        XCTAssertEqual(resolved.tokens.inputBackground.hex, "#1E293B")
        XCTAssertEqual(resolved.tokens.textSecondary.hex, "#94A3B8")
        XCTAssertEqual(resolved.shadow, .noShadow)
        XCTAssertEqual(ThemeResolver.resolve(appearance: Appearance(theme: .flat), branding: merchant, system: .light).shape.radius, 0)
        // The stripe stack starts with the system font: the platform's font, not Inter.
        XCTAssertEqual(ThemeResolver.resolve(appearance: Appearance(theme: .stripe), branding: nil, system: .light).shape.fontFamilies, [])
        XCTAssertEqual(AppearanceValue.fontStack("'Avenir Next', Roboto, sans-serif, Lato"), ["Avenir Next", "Roboto"])
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: nil, system: .light).shape.fontFamilies, ["Inter"],
                       "Inter by default, if the app ships it")
    }

    /// AP-07 draws the loader
    @MainActor func test_AP_07_drawsTheLoader() async {
        XCTAssertEqual(PresentOptions(sessionToken: "t").loader, .skeleton)
        XCTAssertEqual(LoaderStyle(wajubJS: "none"), .spinner)
        XCTAssertEqual(LoaderStyle(wajubJS: "skeleton"), .skeleton)
        XCTAssertTrue(ThemeResolver.resolve(appearance: Appearance(disableAnimations: true), branding: nil, system: .light).disableAnimations)
        XCTAssertFalse(ThemeResolver.resolve(appearance: nil, branding: nil, system: .light).disableAnimations)
        // The loader shows until the first screen.
        let harness = Harness(config: "sdk-config-cm-stripe")
        harness.transport.on("GET", "/pay/session", .gated(Gate(), .fixture("session-cm-aggregate")))
        let controller = harness.makeController { $0.loader = .spinner }
        controller.start()
        XCTAssertEqual(controller.screen, .loading)
        XCTAssertNil(controller.state)
        controller.hostGone()
    }

    /// AP-08 inherits the host theme
    func test_AP_08_inheritsTheHostTheme() {
        let host = InheritedTheme(scheme: .dark, primary: RGBAColor(css: "#1A1A1A"), background: RGBAColor(css: "#000000"),
                                  text: RGBAColor(css: "#EEEEEE"), textSecondary: RGBAColor(css: "#333333"),
                                  inputBorder: RGBAColor(css: "#444444"), fontFamily: "Avenir", borderRadius: 30)
        let usable = host.usable(against: RGBAColor(css: "#000000")!)
        XCTAssertNil(usable.primary, "under 3:1 against the background")
        XCTAssertEqual(usable.text?.hex, "#EEEEEE")
        XCTAssertNil(usable.textSecondary, "under 4.5:1")
        XCTAssertEqual(usable.borderRadius, 22)
        let theme = ThemeResolver.resolve(appearance: Appearance(inherit: true), branding: plain, inherited: host, system: .light)
        XCTAssertEqual(theme.scheme, .dark)
        XCTAssertEqual(theme.tokens.background.hex, "#000000")
        XCTAssertEqual(theme.tokens.primary.hex, "#3B82F6", "the dark default: the host's was unusable")
        XCTAssertEqual(theme.tokens.inputBorder.hex, "#444444")
        XCTAssertEqual(theme.shape.fontFamilies, ["Avenir"])
        XCTAssertEqual(theme.shape.radius, 22)
        // Without `inherit`, the host theme is not read.
        XCTAssertEqual(ThemeResolver.resolve(appearance: nil, branding: plain, inherited: host, system: .light).tokens, ThemeTokens.defaults(.light))
    }

    private func hexes(_ tokens: ThemeTokens) -> [String] {
        [tokens.primary, tokens.primaryPressed, tokens.onPrimary, tokens.background, tokens.surfaceRaised, tokens.surfaceMuted,
         tokens.selectedBackground, tokens.text, tokens.textSecondary, tokens.textPlaceholder, tokens.textDisabled, tokens.link,
         tokens.inputBackground, tokens.inputBorder, tokens.borderStrong, tokens.focusRing, tokens.danger, tokens.dangerBorder,
         tokens.dangerBackground, tokens.success, tokens.successBackground, tokens.warning, tokens.warningBackground,
         tokens.disabledBackground].map(\.hex)
    }
}
