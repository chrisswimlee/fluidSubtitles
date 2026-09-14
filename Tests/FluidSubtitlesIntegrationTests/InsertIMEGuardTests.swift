import XCTest
@testable import FluidSubtitles_Debug

final class InsertIMEGuardTests: XCTestCase {
    func testKoreanAndThaiInputSourcesRequirePaste() {
        XCTAssertTrue(
            InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.inputmethod.Korean.2SetKorean")
        )
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.inputmethod.Korean"))
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.inputmethod.Thai"))
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.keylayout.Thai"))
        XCTAssertFalse(InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.keylayout.US"))
        XCTAssertFalse(InsertIMEGuard.isKoreanOrThaiInputSource("com.apple.keylayout.ABC"))
    }

    func testKoreanAndThaiCaptionLanguages() {
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiLanguage("ko"))
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiLanguage("ko-KR"))
        XCTAssertTrue(InsertIMEGuard.isKoreanOrThaiLanguage("th-TH"))
        XCTAssertFalse(InsertIMEGuard.isKoreanOrThaiLanguage("en"))
        XCTAssertFalse(InsertIMEGuard.isKoreanOrThaiLanguage("en-US"))
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
    }
}
