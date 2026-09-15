import XCTest
@testable import FluidSubtitles_Debug

final class InsertIMEGuardTests: XCTestCase {
    func testKoreanJapaneseAndThaiInputSourcesRequirePaste() {
        XCTAssertTrue(
            InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Korean.2SetKorean")
        )
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Korean"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Kotoeri.Japanese"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Kotoeri.RomajiTyping"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.inputmethod.Thai"))
        XCTAssertTrue(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.Thai"))
        XCTAssertFalse(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.US"))
        XCTAssertFalse(InsertIMEGuard.isIMEInputSource("com.apple.keylayout.ABC"))
    }

    func testKoreanJapaneseAndThaiCaptionLanguages() {
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ko"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ko-KR"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ja"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("ja-JP"))
        XCTAssertTrue(InsertIMEGuard.isIMELanguage("th-TH"))
        XCTAssertFalse(InsertIMEGuard.isIMELanguage("en"))
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
