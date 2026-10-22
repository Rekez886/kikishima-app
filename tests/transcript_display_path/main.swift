import Foundation

let cases: [(directory: String, home: String, expected: String)] = [
    ("/Users/ken/Documents/Kikishima", "/Users/ken", "~/Documents/Kikishima"),
    ("/Users/ken/Meetings/2026", "/Users/ken", "~/Meetings/2026"),
    ("/Users/ken", "/Users/ken", "~"),
    ("/Users/ken/Meetings 中文 会議/2026", "/Users/ken", "~/Meetings 中文 会議/2026"),
    ("/Volumes/External/Kikishima", "/Users/ken", "/Volumes/External/Kikishima"),
    ("/Users/kenji/Docs", "/Users/ken", "/Users/kenji/Docs"),
    ("/Users/ken/Documents/Kikishima", "/Users/ken/", "~/Documents/Kikishima"),
    ("/Users/ken/Documents/Kikishima/", "/Users/ken", "~/Documents/Kikishima"),
    ("/Users/ken/Documents/Kikishima/", "/Users/ken/", "~/Documents/Kikishima"),
    ("/Users/ken/", "/Users/ken", "~"),
    ("/Users/ken", "/Users/ken/", "~"),
    ("/Users/ken/", "/Users/ken/", "~"),
    ("/Users/kenji/Docs", "/Users/ken/", "/Users/kenji/Docs"),
    ("/Volumes/会議 中文/Meeting notes", "/Users/ken", "/Volumes/会議 中文/Meeting notes"),
    ("/Users/ken/100% complete", "/Users/ken", "~/100% complete"),
    ("/", "/", "~"),
    ("/Documents/Kikishima", "/", "~/Documents/Kikishima"),
]

for test in cases {
    let actual = transcriptDisplayPath(
        URL(fileURLWithPath: test.directory),
        homeDirectory: URL(fileURLWithPath: test.home)
    )
    precondition(actual == test.expected, "Expected \(test.expected), got \(actual)")
}
print("PASS: \(cases.count) transcript display path scenarios")
