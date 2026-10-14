import Foundation
func trAny(_ text: String, _ args: CVarArg...) -> String { text }
var count = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }

// Real ledger/cutoff interaction, with successive ASR hypotheses.
var ledger = TranslationSourceLedger()
let first = UUID(), later = UUID()
check(ledger.reconcile("We can approve").rewind == nil, "initial")
ledger.register(first, range: 0..<14)
let correction = ledger.reconcile("We cannot approve")
check(correction.rewind == 0 && correction.removed == [first], "withdraw full old meaning")
let end = translationCutoff(ledger.source, doneChars: correction.rewind!, tuning: .medium, age: 4, stableFor: 2)
check(String(Array(ledger.source)[0..<end]) == "We cannot approve", "send corrected negation intact")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("Yes")
ledger.register(first, range: 0..<3)
check(ledger.reconcile("Yes").removed.isEmpty, "unchanged speech never duplicates")
check(ledger.reconcile("Ye").removed == [first], "shortening withdraws prior chunk")
check(ledger.reconcile("Yes").rewind == nil && ledger.spans.isEmpty, "replacement has no old output left")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("Yes"); ledger.register(first,range:0..<3)
check(ledger.reconcile("Yesterday").removed == [first], "word extension replaces provisional tail")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("We can"); ledger.register(first,range:0..<6)
check(ledger.reconcile("We can not approve").removed == [first], "extended negation replaces provisional tail")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("不"); ledger.register(first,range:0..<1)
check(ledger.reconcile("不能").removed == [first], "CJK continuation replaces provisional tail")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("Yes"); ledger.register(first,range:0..<3)
_ = ledger.finalizedIDs(through:3)
check(ledger.reconcile("Yes next").removed.isEmpty, "finalized previous utterance stays immutable")
ledger = TranslationSourceLedger(); _ = ledger.reconcile("One. Two.")
ledger.register(first, range: 0..<4); ledger.register(later, range: 4..<9)
check(ledger.finalizedIDs(through: 4) == [first], "only immutable source enters summaries")
check(ledger.reconcile("One. Three.").removed == [later], "unaffected prefix retained")
ledger.trim(4, source: " Three.")
check(ledger.source == " Three.", "trim coordinates")

for text in [String(repeating:"word ",count:150)+"end.", String(repeating:"日",count:800),String(repeating:"😀",count:400),"e"+String(repeating:"\u{301}",count:700)] {
 let parts = TranslationText.parts(text)
 check(parts.joined() == text, "lossless long source split")
 check(parts.allSatisfy { $0.utf16.count <= 160 }, "UTF16 safe including surrogate pairs and combining scalars")
}
check(TranslationText.repeatedAcknowledgement("Yes",after:"yes, yes",interval:3), "adjacent acknowledgements reuse translation")
check(!TranslationText.repeatedAcknowledgement("Yes",after:"yes",interval:5), "independent later answer retained")
check(!TranslationText.repeatedAcknowledgement("Yes",after:"Is that approved?",interval:1), "answer after question retained")
let long = String(repeating:"word ",count:150)+"end."
check(translationCutoff(long,doneChars:0,tuning:.medium,age:4,stableFor:3) <= 160, "punctuation cannot bypass cap")
check(translationCutoff("We agree",doneChars:0,tuning:.medium,age:2.1,stableFor:2.1) == 0, "two seconds alone is not a boundary")
check(translationCutoff("We agree",doneChars:0,tuning:.medium,age:4,stableFor:2.1) == 8, "bounded volatile wait")
check(translationCutoff("We agree",doneChars:0,tuning:.medium,age:2.1,stableFor:2.1,finalized:true) == 8, "finalized tail can flush")
check(TranslationText.acknowledgement("Yes, yes, yes!") == "yes", "pure repetition compacted")
for text in ["Yes?", "Yes, but no", "No, no", "Yes we cannot approve", "はい、違います"] {
 check(TranslationText.acknowledgement(text) == nil, "meaningful/question/negative answer preserved")
}
func stream(_ reason: String?, done: Bool) -> TranslationStream {
 var s = TranslationStream()
 s.accept("data: {\"choices\":[{\"delta\":{\"content\":\"approved\"}}]}")
 if let reason { s.accept("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(reason)\"}]}") }
 if done { s.accept("data: [DONE]") }
 return s
}
check(stream("stop",done:true).completed == "approved", "valid completion")
check(stream("stop",done:false).completed == nil, "missing terminal event")
check(stream(nil,done:true).completed == nil, "missing stop reason")
check(stream("length",done:true).completed == nil, "truncation is not success")
check(stream("content_filter",done:true).completed == nil, "filtered result is not success")
var malformed = stream("stop",done:false); malformed.accept("data: broken"); malformed.accept("data: [DONE]")
check(malformed.completed == nil, "malformed output is not success")
check(TranslationText.frozenPreviousSource(immediatePredecessorIsMarker: true, lastNonMarker: "Yes") == "", "marker cuts GPT context")
check(TranslationText.frozenPreviousSource(immediatePredecessorIsMarker: false, lastNonMarker: "Yes") == "Yes", "non-marker predecessor stays")
check(TranslationText.tailPartIsSourceFinal(partEnd: 5, committedCount: 5), "committed tail is source-final")
check(!TranslationText.tailPartIsSourceFinal(partEnd: 8, committedCount: 5), "volatile tail is not source-final")
print("PASS: \(count) source revision, meaning preservation, bounded dispatch, acknowledgement and stream checks")
