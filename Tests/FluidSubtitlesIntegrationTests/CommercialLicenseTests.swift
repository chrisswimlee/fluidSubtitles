import CryptoKit
@testable import FluidSubtitles_Debug
import XCTest

@MainActor
final class CommercialLicenseTests: XCTestCase {
    private var privateKey: Curve25519.Signing.PrivateKey!

    override func setUp() {
        super.setUp()
        self.privateKey = Curve25519.Signing.PrivateKey()
        SettingsStore.licenseVerifyingKeyOverride = self.privateKey.publicKey
        SettingsStore.shared.removeCommercialLicense()
    }

    override func tearDown() {
        SettingsStore.shared.removeCommercialLicense()
        SettingsStore.licenseVerifyingKeyOverride = nil
        super.tearDown()
    }

    func testValidPayloadVerifiesAndExposesOrg() throws {
        let record = try self.makeRecord(org: "Example LLP")
        let token = try CommercialLicense.makeToken(record: record, privateKey: self.privateKey)

        let verified = try CommercialLicense.verify(token, publicKey: self.privateKey.publicKey).get()

        XCTAssertEqual(verified.org, "Example LLP")
        XCTAssertEqual(verified.seats, 25)
        XCTAssertEqual(verified.product, CommercialLicense.productID)
        XCTAssertEqual(verified.licensedToLine, "Licensed to Example LLP")
        XCTAssertTrue(verified.expiryLine().contains("2027"))
    }

    func testWrongSignatureIsRejected() throws {
        let otherKey = Curve25519.Signing.PrivateKey()
        let token = try CommercialLicense.makeToken(
            record: self.makeRecord(),
            privateKey: otherKey
        )

        XCTAssertEqual(
            CommercialLicense.verify(token, publicKey: self.privateKey.publicKey),
            .failure(.badSignature)
        )
    }

    func testWrongProductIsRejected() throws {
        let record = try self.makeRecord(product: "otherApp")
        let token = try CommercialLicense.makeToken(record: record, privateKey: self.privateKey)

        XCTAssertEqual(
            CommercialLicense.verify(token, publicKey: self.privateKey.publicKey),
            .failure(.wrongProduct)
        )
    }

    func testExpiredKeyIsRejected() throws {
        let issued = try XCTUnwrap(CommercialLicense.day(from: "2025-01-01"))
        let expires = try XCTUnwrap(CommercialLicense.day(from: "2025-12-31"))
        let record = CommercialLicense.Record(
            product: CommercialLicense.productID,
            org: "Example LLP",
            seats: 5,
            issued: issued,
            expires: expires
        )
        let token = try CommercialLicense.makeToken(record: record, privateKey: self.privateKey)
        let now = try XCTUnwrap(CommercialLicense.day(from: "2026-01-01"))

        XCTAssertEqual(
            CommercialLicense.verify(token, publicKey: self.privateKey.publicKey, now: now),
            .failure(.expired)
        )
    }

    func testActivateAndRemoveUpdateLicensedState() throws {
        let settings = SettingsStore.shared
        XCTAssertFalse(settings.isCommerciallyLicensed)

        let token = try CommercialLicense.makeToken(
            record: self.makeRecord(org: "Harbor Law"),
            privateKey: self.privateKey
        )
        let activated = settings.activateCommercialLicense(token)

        XCTAssertEqual(try activated.get().org, "Harbor Law")
        XCTAssertTrue(settings.isCommerciallyLicensed)
        XCTAssertEqual(settings.commercialLicenseRecord?.org, "Harbor Law")

        settings.removeCommercialLicense()

        XCTAssertFalse(settings.isCommerciallyLicensed)
        XCTAssertNil(settings.commercialLicenseRecord)
        XCTAssertNil(settings.commercialLicenseToken)
    }

    func testMalformedTokenIsRejected() {
        XCTAssertEqual(CommercialLicense.verify("not-a-key"), .failure(.malformed))
        XCTAssertEqual(
            SettingsStore.shared.activateCommercialLicense("not-a-key"),
            .failure(.malformed)
        )
    }

    func testCommercialLicenseURLsPointAtTheSiteAndMail() {
        XCTAssertEqual(
            FluidProduct.commercialLicenseURL.absoluteString,
            "https://chrisswimlee.com/fluidSubtitles/license/"
        )
        XCTAssertEqual(FluidProduct.commercialLicenseMailURL.scheme, "mailto")
        XCTAssertTrue(FluidProduct.commercialLicenseMailURL.absoluteString.contains("commercial%20license"))
    }

    private func makeRecord(
        product: String = CommercialLicense.productID,
        org: String = "Example LLP"
    ) throws -> CommercialLicense.Record {
        CommercialLicense.Record(
            product: product,
            org: org,
            seats: 25,
            issued: try XCTUnwrap(CommercialLicense.day(from: "2026-09-21")),
            expires: try XCTUnwrap(CommercialLicense.day(from: "2027-09-21"))
        )
    }
}
