import Foundation
import XCTest
@testable import DevEnv

final class UpdateCheckerTests: XCTestCase {
    // MARK: - 版本号

    func testAppVersionParsesPrefixAndPrerelease() {
        XCTAssertEqual(AppVersion("v0.2.4"), AppVersion(major: 0, minor: 2, patch: 4))
        XCTAssertEqual(AppVersion("1.10.0-beta.2"), AppVersion(major: 1, minor: 10, patch: 0, prerelease: ["beta", "2"]))
        XCTAssertEqual(AppVersion("2.0.0+build.7"), AppVersion(major: 2, minor: 0, patch: 0))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.2"))
    }

    func testAppVersionOrderingFollowsSemver() {
        XCTAssertLessThan(v("0.2.4"), v("0.2.10"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"))
        XCTAssertLessThan(v("1.0.0-beta.1"), v("1.0.0"))
        XCTAssertLessThan(v("1.0.0-alpha.1"), v("1.0.0-beta.1"))
        XCTAssertLessThan(v("1.0.0-beta.2"), v("1.0.0-beta.11"))
        XCTAssertEqual(v("1.2.3"), v("v1.2.3"))
    }

    private func v(_ raw: String) -> AppVersion {
        AppVersion(raw)!
    }

    // MARK: - Release 选择

    func testEligibleReleasesSkipsDraftsAndSortsByVersion() {
        let releases = [
            release(tag: "v0.2.3", draft: false, prerelease: true, assets: [dmg("DevEnv-0.2.3-arm64.dmg")]),
            release(tag: "v0.2.4", draft: false, prerelease: true, assets: [dmg("DevEnv-0.2.4-arm64.dmg")]),
            release(tag: "v0.3.0", draft: true, prerelease: true, assets: [dmg("DevEnv-0.3.0-arm64.dmg")]),
            release(tag: "v0.2.2", draft: false, prerelease: true, assets: []),
        ]
        let eligible = UpdateSelection.eligibleReleases(from: releases)
        XCTAssertEqual(eligible.map(\.tagName), ["v0.2.4", "v0.2.3"])
    }

    func testEligibleReleasesCanExcludePrerelease() {
        let releases = [
            release(tag: "v0.2.4", draft: false, prerelease: true, assets: [dmg("DevEnv-0.2.4-arm64.dmg")]),
            release(tag: "v0.2.0", draft: false, prerelease: false, assets: [dmg("DevEnv-0.2.0-arm64.dmg")]),
        ]
        XCTAssertEqual(UpdateSelection.eligibleReleases(from: releases, includePrerelease: false).map(\.tagName), ["v0.2.0"])
    }

    func testMakeUpdateReleasePicksDMGAndChecksumAndDigest() {
        let assets = [
            dmg("DevEnv-0.2.5-arm64.dmg"),
            checksum("DevEnv-0.2.5-arm64.dmg.sha256"),
            dmg("notes.txt"),
        ]
        let github = release(tag: "v0.2.5", draft: false, prerelease: true, assets: assets)
        let update = try? XCTUnwrap(UpdateSelection.makeUpdateRelease(from: github))
        XCTAssertEqual(update?.displayVersion, "0.2.5")
        XCTAssertEqual(update?.dmg.name, "DevEnv-0.2.5-arm64.dmg")
        XCTAssertEqual(update?.checksum?.name, "DevEnv-0.2.5-arm64.dmg.sha256")
        XCTAssertEqual(update?.dmg.expectedSHA256, String(repeating: "a", count: 64))
    }

    func testDigestHexRejectsInvalid() {
        XCTAssertEqual(UpdateSelection.digestHex("sha256:" + String(repeating: "b", count: 64)), String(repeating: "b", count: 64))
        XCTAssertNil(UpdateSelection.digestHex("md5:abc"))
        XCTAssertNil(UpdateSelection.digestHex(nil))
    }

    // MARK: - GitHub JSON 解码

    func testDecodesGitHubReleaseJSON() throws {
        let json = """
        [{
          "tag_name": "v0.2.4",
          "name": "DevEnv v0.2.4 Private Preview",
          "body": "notes",
          "html_url": "https://github.com/my-hosted/DevEnv/releases/tag/v0.2.4",
          "draft": false,
          "prerelease": true,
          "published_at": "2026-10-19T06:57:48Z",
          "assets": [
            {"name": "DevEnv-0.2.4-arm64.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 1024, "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
            {"name": "DevEnv-0.2.4-arm64.dmg.sha256", "browser_download_url": "https://example.com/a.sha256", "size": 90}
          ]
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([GitHubRelease].self, from: Data(json.utf8))
        let update = try XCTUnwrap(UpdateSelection.eligibleReleases(from: releases).first)
        XCTAssertEqual(update.tagName, "v0.2.4")
        XCTAssertTrue(update.isPrerelease)
        XCTAssertEqual(update.dmg.downloadURL.absoluteString, "https://example.com/a.dmg")
        XCTAssertEqual(update.dmg.expectedSHA256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertNotNil(update.publishedAt)
    }

    // MARK: - 校验和

    func testChecksumParsing() {
        let hex = String(repeating: "c", count: 64)
        XCTAssertEqual(SHA256Checksum.parse("\(hex)  DevEnv-0.2.4-arm64.dmg"), hex)
        XCTAssertEqual(SHA256Checksum.parse("*\(hex)"), hex)
        XCTAssertNil(SHA256Checksum.parse("not-a-checksum"))
    }

    func testChecksumMatchesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertTrue(SHA256Checksum.matches(fileAt: file, expectedHex: expected))
        XCTAssertFalse(SHA256Checksum.matches(fileAt: file, expectedHex: String(repeating: "0", count: 64)))
    }

    // MARK: - 控制器

    @MainActor
    func testControllerDetectsUpdateAndDownloadsWithVerifiedChecksum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = Data("dmg-payload".utf8)
        let hex = try writeAndHash(data, in: directory)
        let service = FakeUpdateService(
            release: makeRelease(version: "0.3.0", checksumAvailable: true),
            downloadedData: data,
            checksumText: "\(hex)  DevEnv-0.3.0-arm64.dmg"
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults,
            downloadDirectory: directory
        )

        let shouldPresent = await controller.autoCheckOnLaunch()
        XCTAssertTrue(shouldPresent)
        XCTAssertEqual(controller.phase, .updateAvailable)

        await controller.downloadUpdate()
        guard case let .downloaded(fileURL, checksum) = controller.phase else {
            return XCTFail("期望下载完成，实际为 \(controller.phase)")
        }
        XCTAssertEqual(checksum, .verified)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
    }

    @MainActor
    func testControllerReportsUpToDateAndSkip() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        let service = FakeUpdateService(
            release: makeRelease(version: "0.2.4", checksumAvailable: false),
            downloadedData: Data(),
            checksumText: nil
        )
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        await controller.check()
        XCTAssertEqual(controller.phase, .upToDate)
        XCTAssertFalse(controller.hasAvailableUpdate)
    }

    @MainActor
    func testControllerSkipsVersionOnLaunch() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        let service = FakeUpdateService(
            release: makeRelease(version: "0.3.0", checksumAvailable: false),
            downloadedData: Data(),
            checksumText: nil
        )
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        await controller.check()
        controller.skipCurrentUpdate()
        XCTAssertTrue(controller.isCurrentUpdateSkipped)

        let second = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        let shouldPresent = await second.autoCheckOnLaunch()
        XCTAssertFalse(shouldPresent)
        XCTAssertTrue(second.hasAvailableUpdate)
    }

    // MARK: - 频率限制

    @MainActor
    func testAutomaticCheckSkipsWithinDailyInterval() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        defaults.set(Date(), forKey: UpdateConfiguration.lastAutomaticCheckDefaultsKey)
        let counter = LockedCounter()
        let service = CountingUpdateService(release: makeRelease(version: "0.3.0", checksumAvailable: false), counter: counter)
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        let shouldPresent = await controller.autoCheckOnLaunch()
        XCTAssertFalse(shouldPresent)
        XCTAssertEqual(counter.value, 0, "24 小时内不应再次请求 GitHub")
    }

    @MainActor
    func testAutomaticCheckRunsAfterIntervalElapsed() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        defaults.set(Date(timeIntervalSinceNow: -25 * 60 * 60), forKey: UpdateConfiguration.lastAutomaticCheckDefaultsKey)
        let counter = LockedCounter()
        let service = CountingUpdateService(release: makeRelease(version: "0.3.0", checksumAvailable: false), counter: counter)
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        _ = await controller.autoCheckOnLaunch()
        XCTAssertEqual(counter.value, 1, "超过 24 小时后应重新检查")
    }

    @MainActor
    func testManualCheckCooldownSuppressesRapidRepeat() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DevEnvTests.\(UUID().uuidString)"))
        let counter = LockedCounter()
        let service = CountingUpdateService(release: makeRelease(version: "0.3.0", checksumAvailable: false), counter: counter)
        let controller = UpdateController(
            currentVersion: AppVersion(major: 0, minor: 2, patch: 4),
            service: service,
            defaults: defaults
        )
        await controller.check()
        await controller.check()
        XCTAssertEqual(counter.value, 1, "30 秒冷却内的重复手动检查应被忽略")
    }

    // MARK: - 辅助

    private func writeAndHash(_ data: Data, in directory: URL) throws -> String {
        let file = directory.appendingPathComponent("source-\(UUID().uuidString).bin")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try SHA256Checksum.hexDigest(ofFileAt: file)
    }

    private func makeRelease(version: String, checksumAvailable: Bool) -> UpdateRelease {
        UpdateRelease(
            version: AppVersion(version)!,
            tagName: "v\(version)",
            displayVersion: version,
            title: "DevEnv \(version)",
            releaseNotes: "notes",
            pageURL: URL(string: "https://github.com/my-hosted/DevEnv/releases/tag/v\(version)")!,
            dmg: UpdateAsset(
                name: "DevEnv-\(version)-arm64.dmg",
                downloadURL: URL(string: "https://example.com/DevEnv-\(version)-arm64.dmg")!,
                expectedSHA256: nil,
                byteCount: 1024
            ),
            checksum: checksumAvailable
                ? UpdateAsset(
                    name: "DevEnv-\(version)-arm64.dmg.sha256",
                    downloadURL: URL(string: "https://example.com/DevEnv-\(version)-arm64.dmg.sha256")!,
                    expectedSHA256: nil,
                    byteCount: 100
                )
                : nil,
            publishedAt: nil,
            isPrerelease: true
        )
    }

    private func release(tag: String, draft: Bool, prerelease: Bool, assets: [GitHubReleaseAsset]) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: "DevEnv \(tag)",
            body: "notes",
            htmlURL: URL(string: "https://github.com/my-hosted/DevEnv/releases/tag/\(tag)")!,
            draft: draft,
            prerelease: prerelease,
            publishedAt: nil,
            assets: assets
        )
    }

    private func dmg(_ name: String, digest: String? = "sha256:" + String(repeating: "a", count: 64)) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!,
            size: 1024,
            digest: digest
        )
    }

    private func checksum(_ name: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!,
            size: 90,
            digest: nil
        )
    }
}

private final class FakeUpdateService: UpdateService, @unchecked Sendable {
    let release: UpdateRelease?
    let downloadedData: Data
    let checksumText: String?

    init(release: UpdateRelease?, downloadedData: Data, checksumText: String?) {
        self.release = release
        self.downloadedData = downloadedData
        self.checksumText = checksumText
    }

    func latestRelease() async throws -> UpdateRelease? { release }

    func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.5)
        try downloadedData.write(to: destination)
        progress(1)
        return destination
    }

    func fetchText(from url: URL) async throws -> String { checksumText ?? "" }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class CountingUpdateService: UpdateService, @unchecked Sendable {
    let release: UpdateRelease?
    let counter: LockedCounter

    init(release: UpdateRelease?, counter: LockedCounter) {
        self.release = release
        self.counter = counter
    }

    func latestRelease() async throws -> UpdateRelease? {
        counter.increment()
        return release
    }

    func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Data().write(to: destination)
        return destination
    }

    func fetchText(from url: URL) async throws -> String { "" }
}
