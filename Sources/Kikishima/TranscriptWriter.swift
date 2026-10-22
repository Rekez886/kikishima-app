import Foundation

/// Serializes autosaves and the final transcript write so an older snapshot cannot win a race.
actor TranscriptWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(markdown: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// No suspension between comparison and replacement. Missing, renamed or
    /// edited records must never be recreated by a late network completion.
    func replace(expected: String, with markdown: String, at url: URL) throws {
        try Self.replaceSynchronously(expected: expected, with: markdown, at: url)
    }

    nonisolated static func replaceSynchronously(expected: String, with markdown: String, at url: URL,
                                                 checkingCancellation: Bool = true) throws {
        guard (!checkingCancellation || !Task.isCancelled),
              try String(contentsOf: url, encoding: .utf8) == expected else {
            throw CocoaError(.fileWriteFileExists)
        }
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
