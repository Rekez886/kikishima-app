import Foundation

private enum InjectedFailure: Error {
    case moveFailed
}

private final class SandboxTrashFileManager: FileManager, @unchecked Sendable {
    enum Behavior {
        case move
        case fail
        case omitResult
    }

    private let root: URL
    private let behavior: Behavior
    private(set) var calls = 0

    init(root: URL, behavior: Behavior) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.behavior = behavior
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL result: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        calls += 1
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let destination = root.appendingPathComponent("sandbox-trash", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
            .standardizedFileURL.resolvingSymlinksInPath()
        precondition(source.path.hasPrefix(root.path + "/"), "Source must be inside the test directory")
        precondition(destination.path.hasPrefix(root.path + "/"), "Destination must be inside the test directory")
        if behavior == .fail { throw InjectedFailure.moveFailed }
        try createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try moveItem(at: source, to: destination)
        result?.pointee = behavior == .omitResult ? nil : destination as NSURL
    }
}

@main
private struct TranscriptDeletionTest {
    static func main() throws {
        let files = FileManager()
        guard let temporaryPath = ProcessInfo.processInfo.environment["TMPDIR"] else {
            preconditionFailure("Run through the test wrapper to set TMPDIR")
        }
        let temporaryRoot = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        precondition(temporaryRoot.lastPathComponent.hasPrefix("kikishima-test."), "Run through the test wrapper")
        precondition(["/tmp", "/private/tmp"].contains(temporaryRoot.deletingLastPathComponent().path))
        let root = temporaryRoot.appendingPathComponent("transcript-deletion-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }

        let content = Data("Meeting notes\nA second line.\n".utf8)
        let source = root.appendingPathComponent("success.md")
        let destination = root.appendingPathComponent("sandbox-trash/success.md")
        try content.write(to: source)
        let successfulManager: SandboxTrashFileManager = SandboxTrashFileManager(root: root, behavior: .move)
        let moved = try trashTranscript(at: source, fileManager: successfulManager)
        precondition(successfulManager.calls == 1)
        precondition(moved == destination, "The returned URL must be the sandbox destination")
        precondition(!files.fileExists(atPath: source.path), "The source must be gone")
        let movedContent = try Data(contentsOf: destination)
        precondition(movedContent == content, "The move must preserve all content")

        let failingSource = root.appendingPathComponent("failure.md")
        try content.write(to: failingSource)
        let failingManager: SandboxTrashFileManager = SandboxTrashFileManager(root: root, behavior: .fail)
        do {
            _ = try trashTranscript(at: failingSource, fileManager: failingManager)
            preconditionFailure("The injected failure must propagate")
        } catch InjectedFailure.moveFailed {
            precondition(failingManager.calls == 1)
            precondition(files.fileExists(atPath: failingSource.path), "A failed move must retain its source")
            let remainingContent = try Data(contentsOf: failingSource)
            precondition(remainingContent == content)
            precondition(!files.fileExists(atPath: root.appendingPathComponent("sandbox-trash/failure.md").path))
        }

        let nilSource = root.appendingPathComponent("nil-result.md")
        try content.write(to: nilSource)
        let nilManager: SandboxTrashFileManager = SandboxTrashFileManager(root: root, behavior: .omitResult)
        let nilResult = try trashTranscript(at: nilSource, fileManager: nilManager)
        precondition(nilManager.calls == 1)
        precondition(nilResult == nil, "An absent destination result must remain nil")
        precondition(!files.fileExists(atPath: nilSource.path))
        let nilContent = try Data(contentsOf: root.appendingPathComponent("sandbox-trash/nil-result.md"))
        precondition(nilContent == content)
        print("PASS: transcript deletion stays inside its sandbox")
    }
}
