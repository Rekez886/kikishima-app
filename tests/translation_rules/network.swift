import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }
@main struct NetworkChecks {
 static func main() async {
    let translator = Translator()
    translator.proxyURL = "http://127.0.0.1:" + CommandLine.arguments[1]
    translator.sessionToken = "local-fixture-only"
    func request(_ text: String, previous: String = "") async -> String? {
        await withCheckedContinuation { c in translator.translate(chunk:text,previous:previous,onDelta:{_ in},onDone:{c.resume(returning:$0)}) }
    }
    let a = await request("A", previous:"actual before A")
    let b = await request("B", previous:"A")
    let retryA = await request("A", previous:"actual before A")
    precondition(a == "actual before A|A" && b == "A|B" && retryA == a)
    let drop = await request("DROP"), truncate = await request("TRUNCATE")
    precondition(drop == nil && truncate == nil)
    let ack = await request("Yes, yes, yes")
    precondition(ack == "|yes")
    let long = await request(String(repeating:"example ",count:100),previous:String(repeating:"前文",count:200))
    precondition(long != nil)
    let cancelledID = UUID()
    let cancelled: String? = await withCheckedContinuation { c in
        translator.translate(id:cancelledID,chunk:"SLOW",onDelta:{_ in},onDone:{c.resume(returning:$0)})
        Task { try? await Task.sleep(for:.milliseconds(50)); translator.cancel(cancelledID) }
    }
    precondition(cancelled == nil)
    let afterCancel = await request("AFTER",previous:"new source")
    precondition(afterCancel == "new source|AFTER")
    print("PASS: real loopback HTTP/SSE completion, early EOF, truncation, fixed retry context, acknowledgement and bounded subrequests, cancellation and recovery")
 }
}
