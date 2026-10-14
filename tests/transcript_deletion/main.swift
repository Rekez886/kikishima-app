import Foundation

let fileManager = FileManager.default
let testDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("kikishima-transcript-deletion-\(UUID().uuidString)", isDirectory: true)
let transcript = testDirectory.appendingPathComponent("meeting.md")

try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
try Data("test meeting".utf8).write(to: transcript)

var trashedURL: URL?
defer {
    try? fileManager.removeItem(at: testDirectory)
    if let trashedURL { try? fileManager.removeItem(at: trashedURL) }
}

trashedURL = try trashTranscript(at: transcript, fileManager: fileManager)

precondition(!fileManager.fileExists(atPath: transcript.path), "source transcript should be removed")
precondition(trashedURL != nil, "trash should return the recoverable destination")
precondition(fileManager.fileExists(atPath: trashedURL!.path), "transcript should exist in Trash")
print("PASS: transcript moved to Trash")
