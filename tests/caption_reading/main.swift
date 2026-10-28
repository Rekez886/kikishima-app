import Foundation

precondition(CaptionReadingPolicy.retainedIndices(readable: [], recentLimit: 2).isEmpty)
precondition(CaptionReadingPolicy.retainedIndices(readable: [true, false, false, false], recentLimit: 2) == [0, 2, 3])
precondition(CaptionReadingPolicy.retainedIndices(readable: [true, false, true, false], recentLimit: 2) == [2, 3])
precondition(CaptionReadingPolicy.retainedIndices(readable: [true, true, false], recentLimit: 2) == [1, 2])
precondition(CaptionReadingPolicy.retainedIndices(readable: [true, false, true], recentLimit: 3) == [2, 0, 1])
precondition(CaptionReadingPolicy.retainedIndices(readable: [false, false, false], recentLimit: 2) == [1, 2])
precondition(!CaptionReadingPolicy.isReadable(" \n ", isDraft: false))
precondition(!CaptionReadingPolicy.isReadable("draft", isDraft: true))
precondition(!CaptionReadingPolicy.isReadable("⚠ error", isDraft: false))
precondition(CaptionReadingPolicy.isReadable("A long readable translation", isDraft: false))
print("PASS: pending and out-of-order translations retain newest readable source; drafts and errors excluded")
