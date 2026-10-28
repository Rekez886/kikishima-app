import Foundation

func check(_ condition: Bool) { precondition(condition) }

// Energy VAD fires once per transition, with hysteresis and hangover.
var vad = SpeechActivityDetector()
check(vad.process(levelDB: -70, duration: 0.1) == nil)
check(vad.process(levelDB: -40, duration: 0.1) == nil)
check(vad.process(levelDB: -40, duration: 0.1) == .started)
check(vad.process(levelDB: -40, duration: 0.2) == nil)
check(vad.process(levelDB: -70, duration: 0.2) == nil)
check(vad.process(levelDB: -70, duration: 0.2) == .ended)
check(vad.process(levelDB: -70, duration: 0.2) == nil)
vad.reset()
check(!vad.isSpeaking)

// Pause cuts yield to punctuation when the agreed tail already ends a sentence.
check(endsSentenceTerminal("We agree."))
check(endsSentenceTerminal("He said \"yes.\""))
check(endsSentenceTerminal("（好。）"))
check(!endsSentenceTerminal("We agree"))
check(!endsSentenceTerminal(""))

print("PASS: energy VAD transitions and sentence-terminal detection")
