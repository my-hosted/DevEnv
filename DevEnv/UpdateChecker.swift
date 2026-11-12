import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - 版本号

/// 语义化版本号，支持 `v` 前缀和预发布标识（例如 `v0.2.4`、`1.0.0-beta.1`）。
struct AppVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    /// 预发布标识，稳定版为空。
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        // 丢弃构建元数据（+ 之后的部分）。
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = text[text.index(after: dash)...]
                .split(separator: ".")
                .map(String.init)
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    var displayString: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { text += "-" + prerelease.joined(separator: ".") }
        return text
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false // 稳定版高于同号预发布版
        case (false, true):
            return true
        case (false, false):
            return Self.comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
        }
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Int {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count {
            let left = lhs[index]
            let right = rhs[index]
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            if let leftNumber, let rightNumber {
                if leftNumber != rightNumber { return leftNumber < rightNumber ? -1 : 1 }
            } else if leftNumber != nil {
                return -1 // 数字标识低于字母标识
            } else if rightNumber != nil {
                return 1
            } else if left != right {
                return left < right ? -1 : 1
            }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}

// MARK: - GitHub Releases 模型

/// GitHub Releases API 返回的单个资产。
struct GitHubReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let size: Int
    /// 新版 GitHub 会返回形如 `sha256:<hex>` 的摘要；旧数据可能为空。
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}

/// GitHub Releases API 返回的单个 Release。
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

// MARK: - 可供更新的版本

/// 一个可供下载的更新资产。
struct UpdateAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    /// 已知的 SHA-256 摘要（来自 Release 的 `digest` 字段），可能为空。
    let expectedSHA256: String?
    let byteCount: Int?
}

/// 从 Release 归纳出的更新信息，供 UI 与下载流程使用。
struct UpdateRelease: Equatable, Sendable {
    let version: AppVersion
    let tagName: String
    let displayVersion: String
    let title: String
    let releaseNotes: String
    let pageURL: URL
    let dmg: UpdateAsset
    let checksum: UpdateAsset?
    let publishedAt: Date?
    let isPrerelease: Bool
}

enum UpdateSelection {
    /// 从 Releases 列表中挑选可下载的版本，按版本号从高到低排序。
    /// DevEnv 的 Release 全部是 prerelease，因此默认也接受预发布版本。
    static func eligibleReleases(from releases: [GitHubRelease], includePrerelease: Bool = true) -> [UpdateRelease] {
        releases
            .filter { !$0.draft && (includePrerelease || !$0.prerelease) }
            .compactMap(makeUpdateRelease(from:))
            .sorted { $0.version > $1.version }
    }

    static func makeUpdateRelease(from release: GitHubRelease) -> UpdateRelease? {
        guard let version = AppVersion(release.tagName) ?? release.name.flatMap(AppVersion.init) else {
            return nil
        }
        let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        guard let dmg else { return nil }
        let checksum = release.assets.first { $0.name.lowercased().hasSuffix(".sha256") }
        return UpdateRelease(
            version: version,
            tagName: release.tagName,
            displayVersion: version.displayString,
            title: release.name?.isEmpty == false ? release.name! : "DevEnv \(version.displayString)",
            releaseNotes: release.body ?? "",
            pageURL: release.htmlURL,
            dmg: UpdateAsset(
                name: dmg.name,
                downloadURL: dmg.browserDownloadURL,
                expectedSHA256: digestHex(dmg.digest),
                byteCount: dmg.size
            ),
            checksum: checksum.map {
                UpdateAsset(
                    name: $0.name,
                    downloadURL: $0.browserDownloadURL,
                    expectedSHA256: nil,
                    byteCount: $0.size
                )
            },
            publishedAt: release.publishedAt,
            isPrerelease: release.prerelease
        )
    }

    /// 从 `sha256:<hex>` 形式的摘要中取出十六进制部分。
    static func digestHex(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let hex = digest.lowercased().hasPrefix("sha256:")
            ? String(digest.dropFirst("sha256:".count))
            : digest
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }
}

// MARK: - SHA-256

enum SHA256Checksum {
    /// 解析 `.sha256` 文件内容，返回其中第一个合法的十六进制摘要。
    static func parse(_ text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "*" }) {
            let candidate = String(token).lowercased()
            if candidate.count == 64, candidate.allSatisfy(\.isHexDigit) { return candidate }
        }
        return nil
    }

    static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func matches(fileAt url: URL, expectedHex: String) -> Bool {
        guard let actual = try? hexDigest(ofFileAt: url) else { return false }
        return actual.caseInsensitiveCompare(expectedHex) == .orderedSame
    }
}

// MARK: - 错误

enum UpdateError: LocalizedError {
    case badResponse
    case httpStatus(Int)
    case rateLimited(retryAt: Date?)
    case noEligibleRelease

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "服务器返回了无法识别的内容。"
        case .rateLimited(let retryAt):
            if let retryAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "HH:mm"
                return "GitHub 接口访问频率受限，请在 \(formatter.string(from: retryAt)) 之后重试。未登录时每小时最多 60 次请求。"
            }
            return "GitHub 接口访问频率受限，请稍后重试。未登录时每小时最多 60 次请求。"
        case .httpStatus(let code):
            return "检查更新失败（HTTP \(code)）。"
        case .noEligibleRelease:
            return "没有找到可下载的更新版本。"
        }
    }
}

// MARK: - 非 2xx 响应归类

/// 判断一次非 2xx 的 HTTP 响应是否真的属于 GitHub 频率限制。
///
/// GitHub 的主限流响应通常是 `403` 且 `x-ratelimit-remaining` 为 `0`；次级限流可能返回
/// `403`/`429` 并附带 `retry-after`。`429` 一定是限流，但其他 `403`（例如仓库无权限、
/// 请求被拦截）不应被误报成「访问频率受限」。
enum UpdateHTTPFailure {
    struct Headers {
        var rateLimitRemaining: String?
        var rateLimitReset: String?
        var retryAfter: String?
    }

    static func error(statusCode: Int, headers: Headers, now: Date = Date()) -> UpdateError? {
        guard !(200 ... 299).contains(statusCode) else { return nil }

        let remaining = headers.rateLimitRemaining?.trimmingCharacters(in: .whitespaces)
        let retryAfterSeconds = headers.retryAfter
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { TimeInterval($0) }
            .flatMap { $0 >= 0 ? $0 : nil }

        let isRateLimited = statusCode == 429
            || (statusCode == 403 && (remaining == "0" || retryAfterSeconds != nil))
        guard isRateLimited else { return .httpStatus(statusCode) }

        let retryAt: Date?
        if let retryAfterSeconds {
            retryAt = now.addingTimeInterval(retryAfterSeconds)
        } else if let reset = headers.rateLimitReset
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .flatMap({ TimeInterval($0) }) {
            retryAt = Date(timeIntervalSince1970: reset)
        } else {
            retryAt = nil
        }
        return .rateLimited(retryAt: retryAt)
    }
}

// MARK: - 更新源

/// 抽象更新源，便于测试替换。
protocol UpdateService: Sendable {
    /// 返回最新一个可下载的版本；没有可用版本时返回 `nil`。
    func latestRelease() async throws -> UpdateRelease?
    /// 下载资产到目标文件，并上报 0...1 的进度。
    func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    /// 读取一个纯文本资产（例如 `.sha256` 文件）。
    func fetchText(from url: URL) async throws -> String
}

struct UpdateConfiguration {
    static let repositorySlug = "my-hosted/DevEnv"
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repositorySlug)/releases")!
    static let releasesPageURL = URL(string: "https://github.com/\(repositorySlug)/releases")!
    /// 是否在启动时自动检查更新的持久化开关，默认开启。
    static let automaticCheckDefaultsKey = "DevEnv.autoCheckForUpdates"
    /// 上次自动检查的时间戳，用于限制自动检查频率。
    static let lastAutomaticCheckDefaultsKey = "DevEnv.lastAutomaticUpdateCheckAt"
    /// 自动检查的最小间隔：24 小时。未登录 GitHub API 每小时只有 60 次额度，启动过勤会触发 403。
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    /// 手动检查的最小间隔，避免连续点击消耗额度。
    static let manualCheckCooldown: TimeInterval = 30
}

/// 通过公开的 GitHub Releases API 检查更新。
final class GitHubUpdateService: UpdateService, @unchecked Sendable {
    private let session: URLSession
    private let releasesURL: URL
    private let includePrerelease: Bool

    init(
        session: URLSession = .shared,
        releasesURL: URL = UpdateConfiguration.releasesAPIURL,
        includePrerelease: Bool = true
    ) {
        self.session = session
        self.releasesURL = releasesURL
        self.includePrerelease = includePrerelease
    }

    func latestRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DevEnv", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let headers = UpdateHTTPFailure.Headers(
                rateLimitRemaining: http.value(forHTTPHeaderField: "x-ratelimit-remaining"),
                rateLimitReset: http.value(forHTTPHeaderField: "x-ratelimit-reset"),
                retryAfter: http.value(forHTTPHeaderField: "retry-after")
            )
            throw UpdateHTTPFailure.error(statusCode: http.statusCode, headers: headers)
                ?? .httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([GitHubRelease].self, from: data)
        return UpdateSelection.eligibleReleases(from: releases, includePrerelease: includePrerelease).first
    }

    func download(
        _ asset: UpdateAsset,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = UpdateFileDownloader(destination: destination, progress: progress)
        return try await downloader.download(from: asset.downloadURL)
    }

    func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("DevEnv", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        guard let text = String(data: data, encoding: .utf8) else { throw UpdateError.badResponse }
        return text
    }
}

/// 基于 `URLSessionDownloadTask` 的下载器，支持进度回调。
final class UpdateFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    private var movedDestination: URL?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            movedDestination = destination
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let moveError {
            finish(.failure(moveError))
        } else if let movedDestination {
            finish(.success(movedDestination))
        } else {
            finish(.failure(UpdateError.badResponse))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - 更新流程状态

enum UpdateChecksumResult: Equatable, Sendable {
    case verified
    case unavailable
    case mismatch
}

/// 触发检查的来源，用于区分频率限制。
enum UpdateCheckTrigger {
    case manual
    case automatic
}

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case downloading(progress: Double)
    case downloaded(fileURL: URL, checksum: UpdateChecksumResult)
    case failed(String)
    case unavailable

    static func == (lhs: UpdatePhase, rhs: UpdatePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate),
             (.updateAvailable, .updateAvailable), (.unavailable, .unavailable):
            return true
        case let (.downloading(a), .downloading(b)):
            return a == b
        case let (.downloaded(a, ac), .downloaded(b, bc)):
            return a == b && ac == bc
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }
}

/// 驱动检查更新与下载的界面状态。
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var release: UpdateRelease?

    let currentVersion: AppVersion
    let currentVersionDisplay: String
    let currentBuildDisplay: String
    let releasesPageURL: URL

    private let service: UpdateService
    private let defaults: UserDefaults
    private let downloadDirectory: URL?
    private var hasAutoChecked = false
    private var lastCheckAttemptAt: Date?
    private static let skippedVersionKey = "DevEnv.skippedUpdateVersion"

    init(
        currentVersion: AppVersion? = nil,
        service: UpdateService = GitHubUpdateService(),
        defaults: UserDefaults = .standard,
        releasesPageURL: URL = UpdateConfiguration.releasesPageURL,
        downloadDirectory: URL? = nil
    ) {
        let rawVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = currentVersion ?? rawVersion.flatMap(AppVersion.init) ?? AppVersion(major: 0, minor: 0, patch: 0)
        self.currentVersionDisplay = currentVersion?.displayString ?? rawVersion ?? "0.0.0"
        self.currentBuildDisplay = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        self.service = service
        self.defaults = defaults
        self.releasesPageURL = releasesPageURL
        self.downloadDirectory = downloadDirectory
    }

    /// 是否发现比当前更新的版本。
    var hasAvailableUpdate: Bool {
        guard let release else { return false }
        return release.version > currentVersion
    }

    /// 是否被用户「跳过此版本」。
    var isCurrentUpdateSkipped: Bool {
        guard let release else { return false }
        return defaults.string(forKey: Self.skippedVersionKey) == release.displayVersion
    }

    /// 启动后静默检查一次，返回是否有可展示的新版本。用户关闭自动检查时不做网络请求。
    @discardableResult
    func autoCheckOnLaunch() async -> Bool {
        guard !hasAutoChecked else { return false }
        hasAutoChecked = true
        guard defaults.object(forKey: UpdateConfiguration.automaticCheckDefaultsKey) as? Bool ?? true else {
            return false
        }
        await check(trigger: .automatic)
        return hasAvailableUpdate && !isCurrentUpdateSkipped
    }

    /// 检查更新（不涉及界面展示逻辑，由调用方决定是否呈现窗口）。
    /// 自动检查最多每 24 小时一次，手动检查有 30 秒冷却，避免触发 GitHub 的访问频率限制。
    func check(trigger: UpdateCheckTrigger = .manual) async {
        let now = Date()
        switch trigger {
        case .manual:
            if let last = lastCheckAttemptAt,
               now.timeIntervalSince(last) < UpdateConfiguration.manualCheckCooldown {
                return
            }
        case .automatic:
            if let last = defaults.object(forKey: UpdateConfiguration.lastAutomaticCheckDefaultsKey) as? Date,
               now.timeIntervalSince(last) < UpdateConfiguration.automaticCheckInterval {
                return
            }
        }
        lastCheckAttemptAt = now
        if trigger == .automatic {
            // 无论成功失败都记录尝试时间，失败（例如 403）后也不在当天反复重试。
            defaults.set(now, forKey: UpdateConfiguration.lastAutomaticCheckDefaultsKey)
        }

        phase = .checking
        do {
            let latest = try await service.latestRelease()
            guard let latest else {
                release = nil
                phase = .unavailable
                return
            }
            release = latest
            phase = latest.version > currentVersion ? .updateAvailable : .upToDate
        } catch {
            release = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// 下载当前发现的更新，并在下载后校验 SHA-256。
    func downloadUpdate() async {
        guard let release else { return }
        phase = .downloading(progress: 0)
        let destination = downloadDestination(for: release.dmg.name)
        do {
            let fileURL = try await service.download(release.dmg, to: destination) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(progress: progress)
                }
            }

            // 优先使用 Release 内 `.sha256` 文件，其次使用资产自带的 digest。
            var expected = release.dmg.expectedSHA256
            if let checksum = release.checksum {
                if let text = try? await service.fetchText(from: checksum.downloadURL) {
                    expected = SHA256Checksum.parse(text) ?? expected
                }
            }

            guard let expected else {
                phase = .downloaded(fileURL: fileURL, checksum: .unavailable)
                return
            }
            if SHA256Checksum.matches(fileAt: fileURL, expectedHex: expected) {
                phase = .downloaded(fileURL: fileURL, checksum: .verified)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
                phase = .failed("安装包校验失败，已删除下载文件。请稍后重试或前往发布页手动下载。")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 记录「跳过此版本」，之后启动不再主动提示该版本。
    func skipCurrentUpdate() {
        guard let release else { return }
        defaults.set(release.displayVersion, forKey: Self.skippedVersionKey)
    }

    func openDownloadedFile() {
        guard case let .downloaded(fileURL, _) = phase else { return }
        NSWorkspace.shared.open(fileURL)
    }

    func revealDownloadedFile() {
        guard case let .downloaded(fileURL, _) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openReleasePage() {
        NSWorkspace.shared.open(release?.pageURL ?? releasesPageURL)
    }

    private func downloadDestination(for fileName: String) -> URL {
        let directory = downloadDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeName = fileName.isEmpty ? "DevEnv-update.dmg" : fileName
        var url = directory.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: url.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            url = directory.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        return url
    }
}
