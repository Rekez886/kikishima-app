
final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranslationNetworkTiming] = []
    func add(_ row: TranslationNetworkTiming) { lock.withLock { stored.append(row) } }
    var rows: [TranslationNetworkTiming] { lock.withLock { stored } }
}
@main struct ProbeChecks {
    static func main() {
        let collected = Samples()
        let probe = TranslationNetworkProbe(index: 2, count: 3, retry: 1, report: { collected.add($0) })
        let header = #"{"v":1,"id":42,"route":0,"elapsedMs":90,"d1Calls":3,"cache":0,"attempts":1,"fallback":0,"stages":{"auth":1,"d1":9,"upstreamHeaders":80}}"#
        let url = URL(string: "https://unused.invalid/translate")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["x-kikishima-timing": header])!
        probe.receivedHeaders(response)
        probe.receivedDelta(" ")
        probe.receivedDelta("readable")
        probe.finish()
        precondition(collected.rows.isEmpty, "task delegate completion must arrive before emission")
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url) // Never resumed, no network access.
        probe.urlSession(session, task: task, didCompleteWithError: nil)
        precondition(collected.rows.count == 1)
        let row = collected.rows[0]
        precondition(row.worker?.id == 42 && row.worker?.stages.upstreamHeaders == 80)
        precondition(row.subrequestIndex == 2 && row.subrequestCount == 3 && row.retry == 1)
        precondition(row.requestToHeadersMs != nil && row.headersToFirstMs != nil && row.requestToEndMs != nil)
        probe.finish(); probe.urlSession(session, task: task, didCompleteWithError: nil)
        precondition(collected.rows.count == 1, "late delegate calls cannot emit duplicate diagnostics")
        task.cancel(); session.invalidateAndCancel()
        print("PASS: actual network probe retains Worker header through completion and emits once")
    }
}
