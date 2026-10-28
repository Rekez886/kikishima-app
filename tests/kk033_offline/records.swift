import Foundation
@main struct RecordsTest {
 @MainActor static func main() async throws {
  #if DEBUG || SHOOT
  let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KIKISHIMA_RECORDS_DIR"]!, isDirectory: true)
  DefaultsSpy.saved = "/fictional-saved-directory"
  precondition(CaptionState.transcriptDir == directory && FilesSpy.calls == 0)
  let files = loadTranscripts()
  // /tmp is a symlink to /private/tmp; directory listings return the resolved form.
  func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
  precondition(files.count == 1 && canonical(files[0].url.deletingLastPathComponent()) == canonical(directory))
  let text = try String(contentsOf: files[0].url, encoding: .utf8)
  precondition(RetryHost().canRetryTranscript(at: files[0].url))
  let summaries = SummaryDirectoryHost().directory(files[0].url)
  // The sidecar directory does not exist yet, so compare its existing parent and its name.
  precondition(canonical(summaries.deletingLastPathComponent()) == canonical(directory) && summaries.lastPathComponent == ".kikishima-summaries")
  // Exercise the real writer using only the isolated Markdown fixture.
  let writer = TranscriptWriter()
  try await writer.write(markdown: text, to: files[0].url)
  print("PASS fixture: real listing/reader/writer, retry eligibility, summary sibling directory, no Documents lookup")
  #else
  DefaultsSpy.saved = "/fictional-saved-directory"
  precondition(CaptionState.transcriptDir.path == "/fictional-saved-directory" && FilesSpy.calls == 0)
  DefaultsSpy.saved = nil
  precondition(CaptionState.transcriptDir.path == "/fictional-default-documents/Kikishima" && FilesSpy.calls == 1)
  print("PASS release: existing saved/default record paths unchanged despite environment override")
  #endif
 }
}
