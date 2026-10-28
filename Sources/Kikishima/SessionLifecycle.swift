import Foundation
import Security

/// Exclusive in-flight engine start so overlapping resume/language/reconnect
/// tasks cannot treat CancellationError as a meeting failure.
struct ExclusiveEngineStart {
    private(set) var inFlight = false

    /// Returns false when a start is already running; the caller must no-op.
    mutating func begin() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    mutating func end() {
        inFlight = false
    }

    /// Only a real start failure on the current session should stop the meeting.
    /// Cancellation means another start/stop took the engine.
    static func shouldStopMeeting(cancelled: Bool, sessionStillCurrent: Bool) -> Bool {
        sessionStillCurrent && !cancelled
    }
}

enum SessionControls {
    /// Pause restarts the tap/engine. Doing that during resume or a language
    /// switch cancels the in-flight start and used to tear down the meeting.
    static func canPause(switchingMeetingLanguage: Bool, resuming: Bool) -> Bool {
        !switchingMeetingLanguage && !resuming
    }

    static func canChangeMeetingLanguage(starting: Bool, switchingMeetingLanguage: Bool, resuming: Bool) -> Bool {
        !starting && !switchingMeetingLanguage && !resuming
    }

    enum HotkeyAction: Equatable {
        case start, stop, resume
    }

    /// Pause maps to resume. A resume already in flight maps to stop so the
    /// shortcut is never a no-op while the transcriber is restarting.
    static func hotkeyAction(running: Bool, starting: Bool, paused: Bool, resuming: Bool) -> HotkeyAction {
        if running, resuming { return .stop }
        if running, paused { return .resume }
        if running || starting { return .stop }
        return .start
    }

    /// ASR reconnect must not start a new engine after the user paused or
    /// started a language switch; that overlapping start used to abort the meeting.
    static func shouldRunReconnect(paused: Bool, switchingMeetingLanguage: Bool, resuming: Bool) -> Bool {
        !paused && !switchingMeetingLanguage && !resuming
    }

    static func shouldRebuildAudioTap(running: Bool, paused: Bool, resuming: Bool, switchingMeetingLanguage: Bool, tapAlreadyRunning: Bool) -> Bool {
        running && !paused && !resuming && !switchingMeetingLanguage && !tapAlreadyRunning
    }

    /// A new meeting waits for the previous start task and transcript save,
    /// not the previous summary HTTP. Finalize of the last meeting is isolated
    /// in MeetingSummaryCoordinator so it can finish after begin().
    static func canStartNewMeeting(previousStartInFlight: Bool, previousTranscriptPending: Bool) -> Bool {
        !previousStartInFlight && !previousTranscriptPending
    }

    /// History retry must not start a second summarize for a record that is
    /// still finalizing in the background after the next meeting began.
    static func canRetryMeetingSummary(running: Bool, starting: Bool, recordBusy: Bool) -> Bool {
        !running && !starting && !recordBusy
    }

    /// Chunking must freeze during a language switch. Clearing volatile speech
    /// while the old ledger is still live looks like an ASR revision and
    /// withdraws on-screen captions.
    static func shouldTickChunks(running: Bool, paused: Bool, switchingMeetingLanguage: Bool) -> Bool {
        running && !paused && !switchingMeetingLanguage
    }

    /// Bubble overlay is frozen. Ignore leftover UserDefaults from 0.29.
    static func resolvedBubbleMode(stored: Bool) -> Bool {
        false
    }

    static let productionAPI = "https://api.kikishima.com"

    #if SANDBOX
    static let defaultAPI = "https://api.example.invalid"
    #else
    static let defaultAPI = productionAPI
    #endif

    static func resolvedAPIBase(_ raw: String) -> String {
        #if SANDBOX
        // Every stored value is pinned to this build's server.
        return defaultAPI
        #else
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == productionAPI { return productionAPI }
        #if DEBUG
        if let url = URL(string: trimmed),
           (url.scheme == "http" || url.scheme == "https"),
           url.host == "127.0.0.1" || url.host == "localhost" {
            return trimmed
        }
        #endif
        return productionAPI
        #endif
    }
}

enum CredentialScope: Equatable {
    enum Build: String { case release, debug, shoot, sandbox }
    case production
    case isolated(Build, bundleID: String?)
    case disabled

    static func resolve(bundleID: String?, build: Build, simulation: Bool) -> Self {
        if simulation { return .disabled }
        #if SANDBOX
        return .isolated(.sandbox, bundleID: bundleID)
        #else
        if build == .release, bundleID == "com.kikishima.mac" { return .production }
        return .isolated(build, bundleID: bundleID)
        #endif
    }

    static var current: Self {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return .disabled }
#endif
#if SANDBOX
        let build = Build.sandbox
#elseif SHOOT
        let build = Build.shoot
#elseif DEBUG
        let build = Build.debug
#else
        let build = Build.release
#endif
        return resolve(bundleID: Bundle.main.bundleIdentifier, build: build, simulation: false)
    }

    private var namespace: String {
        switch self {
        case .production: return "production"
        case .isolated(let build, let bundleID):
            // Encoding preserves case and separators without filename/key collisions.
            let identity = bundleID.map { "bundle." + Data($0.utf8).base64EncodedString() } ?? "unbundled"
            return build.rawValue + "." + identity
        case .disabled: return "disabled"
        }
    }

    var keychainService: String { self == .production ? "Kikishima" : "Kikishima.Test." + namespace }
    func defaultsKey(_ key: String) -> String { self == .production ? key : "account." + namespace + "." + key }
}

/// Injectable so storage regression tests never query a real Keychain.
struct CredentialKeychain {
    var read: (_ service: String, _ account: String) -> String
    var write: (_ service: String, _ account: String, _ value: String) -> Bool

    static let system = CredentialKeychain(read: { service, account in
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }, write: { service, account, value in
        let search = query(service: service, account: account)
        if value.isEmpty {
            let status = SecItemDelete(search as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = search
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    })

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

