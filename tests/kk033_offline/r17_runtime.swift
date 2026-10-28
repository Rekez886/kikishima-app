import AppKit
@main struct R17Tests {
    static func main() throws {
        let root = CommandLine.arguments[1]
        if CommandLine.arguments.count > 2 {
            ShootDiagnosticLog.start(at: DispatchTime.now().uptimeNanoseconds)
            ShootDiagnosticLog.shared?.event("probe", "result=ok")
            return
        }
        typealias M = ShootMenuState
        var m = M(now: 0)
        m.step(now: 4, input: .init()); precondition(m.phase == .waitingForStatusItem)
        m.step(now: 5, input: .init()); precondition(m.reason == "status-item-timeout")
        m = M(now: 0); m.step(now: 4, input: .init(statusReady: true))
        precondition(m.phase == .requestingSession && m.attempt == 1)
        m.step(now: 4.1, input: .init()); precondition(m.reason == "session-unavailable")
        m = M(now: 0)
        m.step(now: 0, input: .init(statusReady: true))
        m.step(now: 0.1, input: .init(sessionAvailable: true))
        m.step(now: 5.1, input: .init()); precondition(m.reason == "window-timeout")
        m = M(now: 0)
        m.step(now: 0, input: .init(statusReady: true))
        m.step(now: 0.1, input: .init(sessionAvailable: true))
        m.step(now: 0.2, input: .init(sessionActive: true, windowVisible: true))
        m.step(now: 5.2, input: .init()); precondition(m.reason == "anchor-timeout")
        for failure in [false, true] {
            m = M(now: 0)
            m.step(now: 0, input: .init(statusReady: true))
            m.step(now: 0.1, input: .init(sessionAvailable: true))
            m.step(now: 0.2, input: .init(sessionActive: true, windowVisible: true))
            precondition(m.phase == .anchoring)
            m.step(now: 0.3, input: .init(anchored: !failure))
            precondition(failure ? m.reason == "anchor-outside-visible-frame" : m.phase == .shown)
        }
        m = M(now: 0)
        for attempt in 1...3 {
            let t = Double(attempt)
            m.step(now: t, input: .init(statusReady: true))
            m.step(now: t+0.1, input: .init(sessionAvailable: true))
            m.step(now: t+0.2, input: .init(sessionActive: true, windowVisible: true))
            m.step(now: t+0.3, input: .init(anchored: true))
            precondition(m.phase == .shown && m.attempt == attempt)
            m.step(now: t+0.4, input: .init(sessionActive: true, windowVisible: true))
            precondition(m.phase == .shown)
            m.step(now: t+0.5, input: .init())
        }
        precondition(m.reason == "reopen-limit")
        let a = NSObject(), b = NSObject()
        precondition(ShootStatusInventory.count([]) == 0)
        precondition(ShootStatusInventory.count([ObjectIdentifier(a), ObjectIdentifier(a)]) == 1)
        precondition(ShootStatusInventory.count([ObjectIdentifier(a), ObjectIdentifier(b)]) == 2)
        // AX button 1010,4,36x24 -> Cocoa 1010,954,36x24, 38pt menu bar.
        let frame = ShootMenuPlacement.frame(menuSize: .init(width: 304,height: 752),
            buttonFrame: .init(x:1010,y:954,width:36,height:24),
            visibleFrame: .init(x:0,y:0,width:1512,height:944))
        precondition(frame == NSRect(x:876,y:192,width:304,height:752))
        print("PASS AX 876,38,304x752 (1512x982 screen, button 1010,4,36x24, visible top 38)")
        let path = root + "/runtime.log"
        let logger = try ShootDiagnosticLog(path: path, start: 1_000_000, wall: Date(timeIntervalSince1970: 0), pid: 123, sha: "ee49410")
        logger.event("test", "result=one", now: 3_000_000)
        logger.event("test", "result=two\nforged", now: 3_000_000)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        precondition(lines.count == 3)
        precondition(lines[0].hasPrefix("000000 log-start wall=1970-01-01T09:00:00+09:00 pid=123 sha=ee49410 build="))
        precondition(lines[1] == "000002 test result=one")
        precondition(lines[2] == "000002 test result=two\\nforged")
        let appendedLogger = try ShootDiagnosticLog(path: path, start: 0)
        appendedLogger.event("append", "result=ok", now: 10_000_000)
        let appended = try String(contentsOfFile: path, encoding: .utf8)
        precondition(appended.hasPrefix(text) && appended.hasSuffix("000010 append result=ok\n"))
        let unset = try ShootDiagnosticLog(path: nil, start: 0); unset.event("test", "unset")
        for invalid in ["", "relative.log", root, root + "/missing/file"] {
            do { _ = try ShootDiagnosticLog(path: invalid, start: 0); preconditionFailure("accepted invalid path") } catch {}
        }
        print("PASS state machine, reopen limit, unique object counting, log format/append visibility/monotonic/path validation; no app or window created")
    }
}
