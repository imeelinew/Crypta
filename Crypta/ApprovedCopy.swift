import Foundation

/// The first 19 strings were approved in `crypta-copy-review (2).json`,
/// exported 2026-07-28T03:20:31.012Z. The remaining recovery and failure-state
/// strings were authorized for direct integration on 2026-07-28.
nonisolated enum ApprovedCopy {
    static let vaultLevelLabel = "保险级别"
    static let standardLevelDescription = "打开即可访问；视频使用 IINA 播放"
    static let extendedLevelDescription =
        "需解锁；仅使用内置播放器，切换保险箱后仍保持解锁，也可手动上锁"
    static let maximumLevelDescription =
        "需解锁；仅使用内置播放器，切换保险箱或 App 失焦会自动上锁"
    static let lockedVaultHeading = "保险箱已锁定"
    static let unlockVaultButton = "解锁保险箱"

    static let protectedFormatTitle = "此视频格式无法在受保护保险箱中播放"
    static let protectedFormatMessage =
        "文件仍会安全保存在 Crypta 中。若要播放，请将视频转换为内置播放器支持的格式后重新导入。"

    static let recoveryIntroTitle = "保存你的恢复密钥"
    static let recoveryIntroMessage =
        "如果钥匙串或这台 Mac 无法使用，恢复密钥是重新访问保险箱的唯一方式。Crypta 不会保存可替你恢复的数据副本。"
    static let recoveryCopyButton = "复制恢复密钥"
    static let recoverySaveButton = "存储到文件"
    static let recoveryConfirmLabel = "我已将恢复密钥保存在安全的位置"
    static let recoveryAccessTitle = "使用恢复密钥"
    static let recoveryAccessMessage =
        "输入你保存的恢复密钥，以重新连接这台 Mac 并访问保险箱。恢复过程只在本机进行。"
    static let recoveryAccessField = "恢复密钥"
    static let recoveryAccessButton = "恢复访问"
    static let recoveryAccessInvalid = "恢复密钥无效"
    static let recoveryAccessComplete = "已恢复对保险箱的访问"
    static let recoveryAccessFailure = "无法恢复访问，请稍后重试。"
    static let recoveryFileDefaultName = "Crypta 恢复密钥.txt"

    static let migrationTitle = "升级 Crypta 保险库"
    static let migrationMessage =
        "Crypta 将在本机重新加密现有文件。每个文件只有在新副本通过完整性验证后，才会删除原副本。"
    static let migrationStartButton = "开始安全升级"
    static let migrationComplete = "保险库升级完成"
    static let migrationFailureMessage =
        "保险库升级未完成。Crypta 已保留可用数据，你可以稍后重试。"

    static func migrationProgress(current: Int, total: Int) -> String {
        "正在处理第 \(current) 项，共 \(total) 项"
    }

    static let importSourceCleanupTitle = "原文件未能删除"

    static func importSourceCleanupWarning(count: Int) -> String {
        "有 \(count) 个原文件未能删除；加密副本已经完整验证并安全保留。"
    }

    static let decryptExportMessage =
        "文件成功写入并通过验证后，Crypta 才会删除保险库中的副本。"
}
