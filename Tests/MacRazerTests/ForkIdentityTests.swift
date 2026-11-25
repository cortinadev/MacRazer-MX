// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// MacRazer MX's identity: what lets it sit next to upstream's MacRazer on one Mac, and keeps it
/// off upstream's servers, tracker and releases. Some of it is written in more than one place
/// (the bundle ID in Info.plist, build-app.sh and the crash scanner), and an upstream merge can
/// bring any of upstream's values back without a conflict, so these fail loudly rather than let
/// the two apps quietly share a bundle ID, a data folder or a server.
final class ForkIdentityTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let bundleID = "com.cortinadev.macrazer-mx"

    func testTheBundleIDAndNameAreTheForksEverywhereTheyAreWritten() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: Self.root.appendingPathComponent("Packaging/Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, Self.bundleID)
        XCTAssertEqual(plist["CFBundleName"] as? String, "MacRazer MX")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "MacRazer MX")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "MacRazer", "the SwiftPM target keeps upstream's name")
        XCTAssertEqual(CrashReportParser.bundleID, Self.bundleID)

        let build = try String(contentsOf: Self.root.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        XCTAssertEqual(build.components(separatedBy: "--identifier \(Self.bundleID) ").count - 1, 2,
                       "both codesign calls sign as the fork")
        XCTAssertFalse(build.contains("com.macrazer.menubar"))
        XCTAssertTrue(build.contains("APP=\"MacRazer MX.app\""))
    }

    func testItKeepsItsOwnData() {
        XCTAssertEqual(StoreDirectory.default.lastPathComponent, "MacRazer MX")
    }

    func testItNeverReachesUpstreamsWorkerOrReleases() throws {
        XCTAssertNil(WorkerEndpoint.base)
        XCTAssertNil(WorkerEndpoint.deviceReports)
        XCTAssertNil(WorkerEndpoint.usageStats)
        XCTAssertFalse(AppInfo.updatesEnabled, "the fork has no release feed of its own yet")
        let build = try String(contentsOf: Self.root.appendingPathComponent("Scripts/build-app.sh"), encoding: .utf8)
        XCTAssertFalse(build.contains("Add :MacRazerWorkerURL"), "no Worker address in the bundle")

        for url in [ProjectLinks.repo, ProjectLinks.issues, ProjectLinks.latestRelease, ProjectLinks.releasesAPI,
                    ProjectLinks.dmg(forVersion: "1.0.0"), ProjectLinks.newIssue(title: "Test")] {
            XCTAssertTrue(url.absoluteString.contains("cortinadev/MacRazer-MX"), url.absoluteString)
        }
    }
}
