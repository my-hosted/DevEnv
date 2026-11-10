import AppKit
import SwiftUI

/// 检查更新窗口的内容视图。
struct UpdateView: View {
    @ObservedObject var controller: UpdateController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("DevEnv")
                    .font(.title2.weight(.semibold))
                Text(versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var versionLine: String {
        let build = controller.currentBuildDisplay.isEmpty ? "" : "（Build \(controller.currentBuildDisplay)）"
        return "当前版本 \(controller.currentVersionDisplay)\(build)"
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在检查更新…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)

        case .upToDate:
            statusBlock(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: "已是最新版本",
                detail: "当前版本 \(controller.currentVersionDisplay) 已是最新版本。"
            )

        case .unavailable:
            statusBlock(
                symbol: "questionmark.circle",
                tint: .secondary,
                title: "没有可用的更新",
                detail: "暂时没有找到可下载的更新版本。你仍可前往 GitHub Releases 查看。"
            )

        case .updateAvailable:
            updateAvailableContent

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 10) {
                Text("正在下载更新…").font(.headline)
                ProgressView(value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("安装包会保存到「下载」文件夹，下载完成后可打开安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .downloaded(fileURL, checksum):
            VStack(alignment: .leading, spacing: 10) {
                Label(checksumText(checksum), systemImage: checksumSymbol(checksum))
                    .font(.headline)
                    .foregroundStyle(checksum == .mismatch ? .red : .primary)
                Text(fileURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("打开安装包后，将 DevEnv 拖入「应用程序」文件夹替换旧版本，再重新启动完成更新。运行会话不会跨进程恢复，请先结束需要保留的工作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .failed(let message):
            statusBlock(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "检查更新失败",
                detail: message
            )
        }
    }

    private var updateAvailableContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("发现新版本")
                    .font(.headline)
                if let release = controller.release {
                    Text(release.displayVersion)
                        .font(.headline)
                        .foregroundStyle(.tint)
                    if release.isPrerelease {
                        Text("预览版")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let release = controller.release, !release.releaseNotes.isEmpty {
                ScrollView {
                    Text(release.releaseNotes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            } else {
                Text("该版本没有附加更新说明。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBlock(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func checksumText(_ result: UpdateChecksumResult) -> String {
        switch result {
        case .verified: return "已下载并通过 SHA-256 校验"
        case .unavailable: return "已下载（未提供校验文件）"
        case .mismatch: return "下载文件校验失败"
        }
    }

    private func checksumSymbol(_ result: UpdateChecksumResult) -> String {
        switch result {
        case .verified: return "checkmark.seal.fill"
        case .unavailable: return "seal"
        case .mismatch: return "xmark.seal.fill"
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .updateAvailable:
                Button("稍后") { onClose() }
                Button("跳过此版本") {
                    controller.skipCurrentUpdate()
                    onClose()
                }
                .help("之后启动不再主动提示该版本；仍可在「检查更新」中手动查看。")
                Spacer()
                Button("查看发布页") { controller.openReleasePage() }
                Button("下载更新") {
                    Task { await controller.downloadUpdate() }
                }
                .keyboardShortcut(.defaultAction)

            case .downloaded:
                Spacer()
                Button("在 Finder 中显示") { controller.revealDownloadedFile() }
                Button("打开安装包") { controller.openDownloadedFile() }
                    .keyboardShortcut(.defaultAction)
                Button("关闭") { onClose() }

            default:
                Spacer()
                Button("查看发布页") { controller.openReleasePage() }
                if showsRetryButton {
                    Button("重试") {
                        Task { await controller.check() }
                    }
                }
                Button("关闭") { onClose() }
            }
        }
    }

    private var showsRetryButton: Bool {
        switch controller.phase {
        case .idle, .checking, .upToDate, .unavailable, .failed:
            return true
        default:
            return false
        }
    }
}

/// 承载「检查更新」窗口；整个 App 复用同一个窗口。
@MainActor
final class UpdateWindowController {
    private let controller: UpdateController
    private var window: NSWindow?

    init(controller: UpdateController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let root = UpdateView(controller: controller, onClose: { [weak self] in
                self?.window?.close()
            })
            let hostingController = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable]
            window.title = "检查更新"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.center()
            window.setFrameAutosaveName("DevEnvUpdateWindow")
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
