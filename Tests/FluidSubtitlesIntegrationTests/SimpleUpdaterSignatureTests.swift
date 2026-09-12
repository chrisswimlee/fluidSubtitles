//
//  SimpleUpdaterSignatureTests.swift
//  Fluid
//
//  Update zip signature, team, and checksum policy.
//

import XCTest
@testable import FluidSubtitles_Debug

final class SimpleUpdaterSignatureTests: XCTestCase {
    func testRejectsEmptyAdHocAndUnsetTeamIDs() {
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID(nil))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID(""))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID("not set"))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID("NOT SET"))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID("-"))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID("adhoc"))
        XCTAssertFalse(UpdateSignaturePolicy.isUsableTeamID("ABCDEFGHI"))
        XCTAssertTrue(UpdateSignaturePolicy.isUsableTeamID("ABCD123456"))
    }

    func testRejectsTeamMismatchAndAllowsSameOrAllowlistedTeams() {
        let allowed: Set<String> = ["ABCD123456", "EFGH789012"]
        XCTAssertTrue(
            UpdateSignaturePolicy.accepts(
                currentTeam: "ABCD123456",
                newTeam: "ABCD123456",
                allowed: allowed,
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertTrue(
            UpdateSignaturePolicy.accepts(
                currentTeam: "ABCD123456",
                newTeam: "EFGH789012",
                allowed: allowed,
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            UpdateSignaturePolicy.accepts(
                currentTeam: "ABCD123456",
                newTeam: "ZZZZ999999",
                allowed: allowed,
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            UpdateSignaturePolicy.accepts(
                currentTeam: "ABCD123456",
                newTeam: "not set",
                allowed: allowed,
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            UpdateSignaturePolicy.accepts(
                currentTeam: nil,
                newTeam: "ABCD123456",
                allowed: [],
                bundleIdentifier: FluidProduct.bundleIdentifier
            )
        )
        XCTAssertFalse(
            UpdateSignaturePolicy.accepts(
                currentTeam: "ABCD123456",
                newTeam: "ABCD123456",
                allowed: allowed,
                bundleIdentifier: "com.example.other"
            )
        )
    }

    func testParsesCodesignTeamAndRejectsZipSlip() {
        let output = """
        Executable=/tmp/fluidSubtitles.app/Contents/MacOS/fluidSubtitles
        Identifier=com.fluidsubtitles.app
        Format=app bundle with Mach-O thin (arm64)
        TeamIdentifier=ABCD123456
        designated => identifier "com.fluidsubtitles.app" and certificate leaf[subject.OU] = ABCD123456
        """
        XCTAssertEqual(UpdateSignaturePolicy.teamID(fromCodesignOutput: output), "ABCD123456")
        XCTAssertEqual(
            UpdateSignaturePolicy.bundleIdentifier(fromCodesignOutput: output),
            "com.fluidsubtitles.app"
        )
        XCTAssertTrue(
            UpdateSignaturePolicy.designatedRequirement(fromCodesignOutput: output)?
                .contains("com.fluidsubtitles.app") == true
        )

        let work = URL(fileURLWithPath: "/tmp/update-extract")
        XCTAssertTrue(
            UpdateSignaturePolicy.isSafeExtractedApp(
                work.appendingPathComponent("fluidSubtitles.app"),
                workDirectory: work
            )
        )
        XCTAssertFalse(
            UpdateSignaturePolicy.isSafeExtractedApp(
                URL(fileURLWithPath: "/tmp/evil.app"),
                workDirectory: work
            )
        )
    }

    func testChecksumLookupAndSHA256() {
        let sums = """
        # comment
        abcdef0123456789  fluidsubtitles-1.6.10.zip
        deadbeefdeadbeef *other.zip
        """
        XCTAssertEqual(
            UpdateSignaturePolicy.expectedSHA256(
                fromChecksumFile: sums,
                assetName: "fluidsubtitles-1.6.10.zip"
            ),
            "abcdef0123456789"
        )
        XCTAssertNil(
            UpdateSignaturePolicy.expectedSHA256(fromChecksumFile: sums, assetName: "missing.zip")
        )
        let digest = UpdateSignaturePolicy.hexSHA256(of: Data("fluidSubtitles".utf8))
        XCTAssertEqual(digest.count, 64)
    }
}
