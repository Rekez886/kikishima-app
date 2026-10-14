import Foundation
let waiting = CaptionPreviewText(segments: [("one", "一"), ("two", "")], pendingSource: "three", pendingTranslation: "三", translationPaused: false)
precondition(waiting.source == "one\ntwo\nthree")
precondition(waiting.translation == "一\n…\n三")
let paused = CaptionPreviewText(segments: [("two", "")], pendingSource: "", pendingTranslation: "", translationPaused: true)
precondition(paused.translation == "two")
let empty = CaptionPreviewText(segments: [], pendingSource: "", pendingTranslation: "", translationPaused: false)
precondition(empty.source.isEmpty && empty.translation.isEmpty)
print("PASS: completed text, waiting translation, pending ASR/draft, paused fallback, empty preview")
