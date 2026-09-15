@testable import FluidSubtitles_Debug
import AppKit
import XCTest

final class LiveTranslationVisibilityTests: XCTestCase {
    func testTransparentLightDoesNotUseBlackCaptions() {
        let colors = TheaterCaptionVisibility.colors(
            appearance: .light,
            presentation: .transparent,
            highContrast: false
        )
        let translated = self.rgb(colors.translated)
        XCTAssertGreaterThan(translated.r, 0.9)
        XCTAssertGreaterThan(translated.g, 0.9)
        XCTAssertGreaterThan(translated.b, 0.9)
        XCTAssertNotNil(colors.shadowColor)
        XCTAssertGreaterThan(colors.shadowBlur, 2)
        let halo = self.rgb(colors.shadowColor ?? .white)
        XCTAssertLessThan(halo.r, 0.2)
    }

    func testLightPopupSpokenIsDarkEnoughForAWhiteBoard() {
        let colors = TheaterCaptionVisibility.colors(
            appearance: .light,
            presentation: .popup,
            highContrast: false
        )
        let spoken = self.rgb(colors.spoken)
        let brightness = (spoken.r + spoken.g + spoken.b) / 3
        XCTAssertLessThan(brightness, 0.5)
        XCTAssertEqual(colors.translated, .black)
        XCTAssertNil(colors.shadowColor)
    }

    func testDarkPopupUsesWhiteTitleAndDimSpokenUndertone() {
        let colors = TheaterCaptionVisibility.colors(
            appearance: .dark,
            presentation: .popup,
            highContrast: true
        )
        XCTAssertEqual(colors.translated, .white)
        XCTAssertGreaterThan(colors.spoken.alphaComponent, 0.7)
        XCTAssertLessThan(colors.spoken.alphaComponent, 0.85)
        let spoken = self.rgb(colors.spoken)
        XCTAssertGreaterThan(spoken.r, 0.9)
        XCTAssertNotNil(colors.shadowColor)
    }

    func testFinishedTranslationKeepsFullOpacity() {
        let applied = TheaterCaptionVisibility.appliedAlphas(
            spoken: NSColor.white.withAlphaComponent(0.58),
            translated: .white,
            isCurrent: false
        )
        XCTAssertEqual(applied.translated.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(applied.spoken.alphaComponent, 0.88)
        XCTAssertLessThan(applied.spoken.alphaComponent, 1)
    }

    private func rgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }
}
