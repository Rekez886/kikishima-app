import Foundation

typealias TrashItemOperation = (URL) throws -> URL?

/// 把会议记录移入 macOS 废纸篓，返回可恢复的目标位置。
@discardableResult
func trashTranscript(at url: URL, fileManager: FileManager = .default) throws -> URL? {
    var resultingURL: NSURL?
    try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    return resultingURL as URL?
}
