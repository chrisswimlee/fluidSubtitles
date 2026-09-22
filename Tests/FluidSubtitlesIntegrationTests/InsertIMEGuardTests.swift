import XCTest
@testable import FluidSubtitles_Debug

final class InsertIMEGuardTests: XCTestCase {
    func testShortcutInsertTypesIntoTheCapturedAppEvenIfFluidIsFront() {
        XCTAssertTrue(
            TheaterInsertDelivery.shouldTypeCurrentListen(
                text: "안녕.",
                targetBundleID: "com.apple.Notes",
                selfBundleID: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            TheaterInsertDelivery.shouldTypeCurrentListen(
                text: "안녕.",
                targetBundleID: FluidProduct.bundleIdentifier,
                selfBundleID: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            TheaterInsertDelivery.shouldTypeCurrentListen(
                text: "안녕.",
                targetBundleID: nil,
                selfBundleID: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            TheaterInsertDelivery.shouldTypeCurrentListen(
                text: "   ",
                targetBundleID: "com.apple.Notes",
                selfBundleID: FluidProduct.bundleIdentifier
            )
        )
    }

    func testKoreanJapaneseAndThaiInputSourcesRequirePaste() {
        XCTAssertTrue(
            InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Korean.2SetKorean")
        )
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Korean"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Kotoeri.RomajiTyping"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Thai"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.Thai"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.SCIM.ITABC"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.TCIM.Pinyin"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.Arabic"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.Hebrew"))
        XCTAssertFalse(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.US"))
        XCTAssertFalse(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.ABC"))
    }

    func testKoreanJapaneseAndThaiCaptionLanguages() {
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ko"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ko-KR"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ja"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ja-JP"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("th-TH"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("zh"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("zh-TW"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ar"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("he"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("hi-IN"))
        XCTAssertFalse(InsertIMEGuard.isIMELanguage("en"))
        XCTAssertFalse(InsertIMEGuard.isIMELanguage("fr"))
        XCTAssertFalse(InsertIMEGuard.isIMELanguage("en-US"))
    }

    func testASCIICapableUSLayoutAllowsUnicodeInjection() {
        let us = InsertIMEGuard.snapshot(
            identifier: "com.apple.keylayout.US",
            isASCIICapable: true
        )
        XCTAssertFalse(InsertIMEGuard.snapshotRequiresPaste(us))
    }

    func testNonASCIIOrKoreanSnapshotRequiresPaste() {
        let hangul = InsertIMEGuard.snapshot(
            identifier: "com.apple.inputmethod.Korean.2SetKorean",
            isASCIICapable: false
        )
        XCTAssertTrue(InsertIMEGuard.snapshotRequiresPaste(hangul))
        let thaiLayout = InsertIMEGuard.snapshot(
            identifier: "com.apple.keylayout.Thai",
            isASCIICapable: true
        )
        XCTAssertTrue(InsertIMEGuard.snapshotRequiresPaste(thaiLayout))
        let kotoeri = InsertIMEGuard.snapshot(
            identifier: "com.apple.inputmethod.Kotoeri.Japanese",
            isASCIICapable: false
        )
        XCTAssertTrue(InsertIMEGuard.snapshotRequiresPaste(kotoeri))
    }
}
