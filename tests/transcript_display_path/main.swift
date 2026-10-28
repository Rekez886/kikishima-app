import Foundation

let cases: [(directory: String, home: String, expected: String)] = [
    ("/Users/example/Documents/Kikishima", "/Users/example", "~/Documents/Kikishima"),
    ("/Users/example/Meetings/2026", "/Users/example", "~/Meetings/2026"),
    ("/Users/example", "/Users/example", "~"),
    ("/Users/example/Meetings 中文 会議/2026", "/Users/example", "~/Meetings 中文 会議/2026"),
    ("/Volumes/External/Kikishima", "/Users/example", "/Volumes/External/Kikishima"),
    ("/Users/example2/Docs", "/Users/example", "/Users/example2/Docs"),
    ("/Users/example/Documents/Kikishima", "/Users/example/", "~/Documents/Kikishima"),
    ("/Users/example/Documents/Kikishima/", "/Users/example", "~/Documents/Kikishima"),
    ("/Users/example/Documents/Kikishima/", "/Users/example/", "~/Documents/Kikishima"),
    ("/Users/example/", "/Users/example", "~"),
    ("/Users/example", "/Users/example/", "~"),
    ("/Users/example/", "/Users/example/", "~"),
    ("/Users/example2/Docs", "/Users/example/", "/Users/example2/Docs"),
    ("/Volumes/会議 中文/Meeting notes", "/Users/example", "/Volumes/会議 中文/Meeting notes"),
    ("/Users/example/100% complete", "/Users/example", "~/100% complete"),
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
