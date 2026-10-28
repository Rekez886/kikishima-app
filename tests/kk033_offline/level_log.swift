@main struct LevelLogTest {
    static func main() {
        let path = CommandLine.arguments[1]
        CaptionLevelLog.append(level: 0.0)
        CaptionLevelLog.append(level: 0.02)
        CaptionLevelLog.append(level: 0.021)
        if ProcessInfo.processInfo.environment["KIKISHIMA_LEVEL_LOG"] == nil {
            Thread.sleep(forTimeInterval: 0.1)
            precondition(!FileManager.default.fileExists(atPath: path))
            print("PASS level log: unset environment creates no file")
            return
        }
        if CommandLine.arguments.contains("unwritable") {
            Thread.sleep(forTimeInterval: 0.1)
            print("PASS level log: invalid destination does not interrupt caller")
            return
        }
        let deadline = Date().addingTimeInterval(3)
        var lines: [String] = []
        while Date() < deadline {
            lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.count == 3 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        precondition(lines.count == 3)
        let expected = ["level=0.0 voiceDetected=false", "level=0.02 voiceDetected=false", "level=0.021 voiceDetected=true"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (line, suffix) in zip(lines, expected) {
            precondition(line.hasSuffix(suffix))
            precondition(formatter.date(from: String(line.split(separator: " ")[0])) != nil)
        }
        print("PASS level log: three appended numeric-only ISO8601 lines and strict > 0.02 threshold")
    }
}
