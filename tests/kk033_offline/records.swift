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
  let record = TranscriptRecovery.decode(text)!
  precondition(record.incompleteCount == 1 && record.rows.count == 2)
  precondition(record.rows[1].translation.isEmpty && !record.rows[1].complete && !record.rows[1].source.isEmpty)
  let encoded = try record.markdown()
  precondition(TranscriptRecovery.decode(encoded)?.body == record.body)
  precondition(RetryHost().canRetryTranscript(at: files[0].url))
  let summaries = SummaryDirectoryHost().directory(files[0].url)
  // The sidecar directory does not exist yet, so compare its existing parent and its name.
  precondition(canonical(summaries.deletingLastPathComponent()) == canonical(directory) && summaries.lastPathComponent == ".kikishima-summaries")
  // Real writer and recovery runner: retry only the incomplete row, never network.
  let writer = TranscriptWriter()
  try await writer.write(markdown: text, to: files[0].url)
  var retried = 0
  try await TranscriptRecoveryRun.run(record: record, markdown: text, url: files[0].url,
    deadline: .now.advanced(by: .seconds(3)), translate: { row, _, _ in
      precondition(row.source == record.rows[1].source); retried += 1
      return "Let us plant blue flowers in the fictional moon garden."
    }, replace: { old, new, url in try await writer.replace(expected: old, with: new, at: url) }, didSave: {})
  precondition(retried == 1 && FilesSpy.calls == 0)
  let finished = try String(contentsOf: files[0].url, encoding: .utf8)
  precondition(TranscriptRecovery.decode(finished) == nil && !finished.contains("kikishima-recovery-v1"))
  print("PASS fixture: real listing/reader/writer/retry, blank incomplete row retryable, summary directory isolated, no Documents lookup")
  #else
  DefaultsSpy.saved = "/fictional-saved-directory"
  precondition(CaptionState.transcriptDir.path == "/fictional-saved-directory" && FilesSpy.calls == 0)
  DefaultsSpy.saved = nil
  precondition(CaptionState.transcriptDir.path == "/fictional-default-documents/Kikishima" && FilesSpy.calls == 1)
  print("PASS release: existing saved/default record paths unchanged despite environment override")
  #endif
 }
}
