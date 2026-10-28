// 自动更新：Sparkle 2。检查按钮 / 自动检查开关 / 更新弹窗（版本号 + 更新内容 + 立即或稍后）由 Sparkle 标准 UI 提供
// appcast: Info.plist SUFeedURL；签名验证：SUPublicEDKey（release.sh 用 sign_update 和钥匙串中的私钥签 DMG）
import Foundation
import Sparkle

@MainActor
final class UpdaterController {
    static let shared = UpdaterController()
    #if SANDBOX
    private init() {}
    func checkForUpdates() {}
    var automaticallyChecks: Bool { get { false } set {} }
    var automaticallyDownloads: Bool { get { false } set {} }
    var canCheck: Bool { false }
    var lastCheck: Date? { nil }
    #else
    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true → 按 SUScheduledCheckInterval 在后台检查（首次启动 Sparkle 不再另外弹询问，我们用自己的开关）
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    /// 用户点「检查更新」：有更新弹标准窗（版本号 + release notes + 立即安装 / 稍后 / 跳过），没有就提示已是最新
    func checkForUpdates() { controller.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    /// 静默下载并在下次启动时安装（用户无感；关掉则只提示）
    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
    var canCheck: Bool { updater.canCheckForUpdates }
    var lastCheck: Date? { updater.lastUpdateCheckDate }
    #endif
}
