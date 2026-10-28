import Foundation
// Production contract: keep the draining generation valid until final transcript capture.
let generation = 41
for draining in [false, true] {
    precondition(TranscriptionResultPolicy.accepts(resultGeneration: generation,
        currentGeneration: generation, draining: draining, finished: false),
        "audit14: current recognition results, including finalize tail, must be accepted")
}
precondition(!TranscriptionResultPolicy.accepts(resultGeneration: 40,
    currentGeneration: generation, draining: true, finished: false), "audit14: old engine must stay rejected")
precondition(!TranscriptionResultPolicy.accepts(resultGeneration: generation,
    currentGeneration: generation, draining: false, finished: true), "audit14: completed recording rejects late results")
print("PASS audit14 result acceptance")
