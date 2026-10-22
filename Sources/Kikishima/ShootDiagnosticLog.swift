#if SHOOT || DEBUG
import Foundation

/// Synchronous append of one short line; no timers, subprocesses or disk sync on the UI thread.
final class ShootDiagnosticLog {
    static var shared: ShootDiagnosticLog?
    var enabled: Bool { file != nil }
    private let file: FileHandle?
    private let start: UInt64
    private var last: UInt64 = 0
    private let lock = NSLock()

    init(path: String?, start: UInt64, wall: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         sha: String? = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String) throws {
        self.start = start
        guard let path else { file = nil; return }
        guard !path.isEmpty, path.hasPrefix("/") else { throw LogError.invalidPath }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw LogError.openFailed(errno) }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let format = ISO8601DateFormatter()
        format.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
#if SHOOT
        let build = "SHOOT"
#else
        let build = "DEBUG"
#endif
        try file?.write(contentsOf: Data("000000 log-start wall=\(format.string(from: wall)) pid=\(pid) sha=\(sha ?? "unknown") build=\(build)\n".utf8))
    }
    enum LogError: Error { case invalidPath, openFailed(Int32) }
    func event(_ event: String, _ fields: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let file else { return }
        lock.lock(); defer { lock.unlock() }
        // Elapsed monotonic milliseconds; events within one millisecond share a timestamp.
        last = max(last, now >= start ? (now - start) / 1_000_000 : 0)
        let clean = fields.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        do { try file.write(contentsOf: Data((String(format: "%06llu", last) + " \(event) \(clean)\n").utf8)) }
        catch { fputs("KIKISHIMA_SHOOT_LOG: write failed \(error)\n", stderr); exit(1) }
    }
    static func start(at anchor: UInt64) {
        do { shared = try ShootDiagnosticLog(path: ProcessInfo.processInfo.environment["KIKISHIMA_SHOOT_LOG"], start: anchor) }
        catch { fputs("Invalid KIKISHIMA_SHOOT_LOG: \(error)\n", stderr); exit(1) }
    }
}
#endif
