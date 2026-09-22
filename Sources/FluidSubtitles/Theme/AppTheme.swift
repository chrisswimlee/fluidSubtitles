import SwiftUI

/// Central theme definition for the Fluid app. All colors, spacings and materials
/// should be defined here to keep styling consistent and easy to evolve.
struct AppTheme {
    struct Palette {
        let windowBackground: Color
        let contentBackground: Color
        let sidebarBackground: Color
        let cardBackground: Color
        let elevatedCardBackground: Color
        let toolbarBackground: Color
        let cardBorder: Color
        let separator: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let accent: Color
        let warning: Color
        let success: Color
    }

    struct Typography {
        let displayTitle: Font
        let statement: Font
        let title: Font
        let titleIcon: Font
        let sectionTitle: Font
        let body: Font
        let bodyStrong: Font
        let bodySmall: Font
        let bodySmallStrong: Font
        let caption: Font
        let captionStrong: Font
        let captionSmall: Font
        let tiny: Font
        let tinyStrong: Font
        let badge: Font
        let metricTiny: Font
        let codeCaption: Font
        let sidebarItem: Font
        let sidebarSection: Font
        let chromeCaption: Font

        /// Semantic styles track the user's text size. Caption-board sizes stay on the presenter font.
        static let standard = Typography(
            displayTitle: .largeTitle,
            statement: .title3,
            title: .title2,
            titleIcon: .title2,
            sectionTitle: .headline,
            body: .body,
            bodyStrong: .body.weight(.medium),
            bodySmall: .callout,
            bodySmallStrong: .callout.weight(.medium),
            caption: .caption,
            captionStrong: .caption.weight(.medium),
            captionSmall: .caption2,
            tiny: .caption2,
            tinyStrong: .caption2.weight(.medium),
            badge: .caption2.weight(.medium),
            metricTiny: .system(.caption2, design: .rounded).weight(.medium),
            codeCaption: .system(.caption, design: .monospaced),
            sidebarItem: .body,
            sidebarSection: .caption,
            chromeCaption: .caption
        )
    }

    struct Metrics {
        struct Spacing {
            let xs: CGFloat
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let xl: CGFloat
            let xxl: CGFloat

            static let standard = Spacing(
                xs: 4,
                sm: 8,
                md: 12,
                lg: 16,
                xl: 20,
                xxl: 28
            )
        }

        struct CornerRadius {
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let pill: CGFloat

            static let standard = CornerRadius(
                sm: 6,
                md: 10,
                lg: 16,
                pill: 999
            )
        }

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
            let opacity: Double

            static func subtle(color: Color, opacity: Double = 0.45) -> Shadow {
                Shadow(color: color, radius: 12, x: 0, y: 6, opacity: opacity)
            }
        }

        struct FormRow {
            let horizontalPadding: CGFloat
            let verticalPadding: CGFloat
            let cornerRadius: CGFloat
            let materialOpacity: Double
            let borderOpacity: Double

            static let standard = FormRow(
                horizontalPadding: 0,
                verticalPadding: 10,
                cornerRadius: 0,
                materialOpacity: 0,
                borderOpacity: 0
            )
        }

        struct PickerControl {
            let horizontalPadding: CGFloat
            let verticalPadding: CGFloat
            let cornerRadius: CGFloat
            let borderOpacity: Double
            let searchBorderOpacity: Double
            let disclosureSize: CGFloat
            let disclosureBorderOpacity: Double
            let selectedRowOpacity: Double

            static let standard = PickerControl(
                horizontalPadding: 0,
                verticalPadding: 4,
                cornerRadius: 0,
                borderOpacity: 0,
                searchBorderOpacity: 0,
                disclosureSize: 16,
                disclosureBorderOpacity: 0,
                selectedRowOpacity: 0
            )
        }

        struct CardSurface {
            struct Variant {
                let borderOpacity: Double
                let hoverBorderOpacity: Double
                let borderWidth: CGFloat
                let hoverShadowBoost: Double
            }

            let defaultPadding: CGFloat
            let standard: Variant
            let prominent: Variant
            let subtle: Variant

            static let defaults = CardSurface(
                defaultPadding: 0,
                standard: Variant(
                    borderOpacity: 0,
                    hoverBorderOpacity: 0,
                    borderWidth: 0,
                    hoverShadowBoost: 0
                ),
                prominent: Variant(
                    borderOpacity: 0,
                    hoverBorderOpacity: 0,
                    borderWidth: 0,
                    hoverShadowBoost: 0
                ),
                subtle: Variant(
                    borderOpacity: 0,
                    hoverBorderOpacity: 0,
                    borderWidth: 0,
                    hoverShadowBoost: 0
                )
            )
        }

        struct OnboardingSurface {
            struct Landing {
                let contentWidth: CGFloat
                let heroPadding: CGFloat
                let heroIconSize: CGFloat
                let heroIconFrame: CGFloat
                let tileSpacing: CGFloat
                let sectionSpacing: CGFloat
                let heroCornerRadius: CGFloat
            }

            let normalFillOpacity: Double
            let selectedFillOpacity: Double
            let normalBorderOpacity: Double
            let selectedBorderOpacity: Double
            let editorBorderOpacity: Double
            let editorPadding: CGFloat
            let optionPadding: CGFloat
            let compactOptionPadding: CGFloat
            let optionCornerRadius: CGFloat
            let compactOptionCornerRadius: CGFloat
            let editorCornerRadius: CGFloat
            let landing: Landing

            static let standard = OnboardingSurface(
                normalFillOpacity: 0,
                selectedFillOpacity: 0,
                normalBorderOpacity: 0,
                selectedBorderOpacity: 0,
                editorBorderOpacity: 0,
                editorPadding: 0,
                optionPadding: 0,
                compactOptionPadding: 0,
                optionCornerRadius: 0,
                compactOptionCornerRadius: 0,
                editorCornerRadius: 0,
                landing: Landing(
                    contentWidth: 820,
                    heroPadding: 28,
                    heroIconSize: 48,
                    heroIconFrame: 68,
                    tileSpacing: 12,
                    sectionSpacing: 16,
                    heroCornerRadius: 18
                )
            )
        }

        struct Window {
            let mainMinWidth: CGFloat
            let mainMinHeight: CGFloat
            let onboardingMinWidth: CGFloat
            let onboardingMinHeight: CGFloat

            static let standard = Window(
                mainMinWidth: 800,
                mainMinHeight: 500,
                onboardingMinWidth: 940,
                onboardingMinHeight: 700
            )
        }

        let spacing: Spacing
        let corners: CornerRadius
        let formRow: FormRow
        let pickerControl: PickerControl
        let cardSurface: CardSurface
        let onboardingSurface: OnboardingSurface
        let window: Window
        let cardShadow: Shadow
        let elevatedCardShadow: Shadow
    }

    struct Materials {
        let window: Material
        let sidebar: Material
        let card: Material
        let elevatedCard: Material
        let formRow: Material
        let toolbar: Material
    }

    let palette: Palette
    let typography: Typography
    let metrics: Metrics
    let materials: Materials

    static func adaptive(accent: Color, colorScheme: ColorScheme) -> AppTheme {
        switch colorScheme {
        case .light:
            return .light(accent: accent)
        case .dark:
            return .dark(accent: accent)
        @unknown default:
            return .dark(accent: accent)
        }
    }

    /// Warm paper. Label colors stay on the system so contrast settings still apply.
    static func light(accent: Color) -> AppTheme {
        let paper = Color(red: 0.973, green: 0.965, blue: 0.949)
        return AppTheme(
            palette: Palette(
                windowBackground: paper,
                contentBackground: paper,
                sidebarBackground: paper,
                cardBackground: paper,
                elevatedCardBackground: paper,
                toolbarBackground: paper,

                cardBorder: .clear,
                separator: Color.black.opacity(0.12),
                primaryText: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accent,
                warning: Color(nsColor: .systemOrange),
                success: accent
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                formRow: .standard,
                pickerControl: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                cardShadow: .subtle(color: .black, opacity: 0),
                elevatedCardShadow: .subtle(color: .black, opacity: 0)
            ),
            materials: Materials(
                window: .thinMaterial,
                sidebar: .ultraThinMaterial,
                card: .thinMaterial,
                elevatedCard: .regularMaterial,
                formRow: .ultraThinMaterial,
                toolbar: .ultraThinMaterial
            )
        )
    }

    /// Warm black. Label colors stay on the system so contrast settings still apply.
    static func dark(accent: Color) -> AppTheme {
        let ink = Color(red: 0.063, green: 0.055, blue: 0.047)
        return AppTheme(
            palette: Palette(
                windowBackground: ink,
                contentBackground: ink,
                sidebarBackground: ink,
                cardBackground: ink,
                elevatedCardBackground: ink,
                toolbarBackground: ink,

                cardBorder: .clear,
                separator: Color.white.opacity(0.10),
                primaryText: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accent,
                warning: Color(nsColor: .systemOrange),
                success: accent
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                formRow: .standard,
                pickerControl: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                cardShadow: .subtle(color: .black, opacity: 0),
                elevatedCardShadow: .subtle(color: .black, opacity: 0)
            ),
            materials: Materials(
                window: .thinMaterial,
                sidebar: .ultraThinMaterial,
                card: .thinMaterial,
                elevatedCard: .regularMaterial,
                formRow: .ultraThinMaterial,
                toolbar: .ultraThinMaterial
            )
        )
    }

    static let light = AppTheme.light(accent: .fluidGreen)
    static let dark = AppTheme.dark(accent: .fluidGreen)
}

// MARK: - Helpers
