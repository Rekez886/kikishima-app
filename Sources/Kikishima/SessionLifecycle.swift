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

    static func resolvedAPIBase(_ raw: String) -> String {
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
    }
}

enum SessionTokenMigration {
    static func resolve(keychain: String, defaults: String) -> (token: String, persistKeychain: String?, clearDefaultsIfPersisted: Bool) {
        let keychain = keychain.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = defaults.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keychain.isEmpty { return (keychain, nil, true) }
        if !defaults.isEmpty { return (defaults, defaults, true) }
        return ("", nil, false)
    }

    /// Drop the plaintext copy only after the Keychain write actually succeeded,
    /// or when the Keychain already holds the token. A failed add must keep
    /// UserDefaults so the next launch is not signed out.
    static func shouldClearDefaults(keychainWriteSucceeded: Bool, keychainAlreadyHeldToken: Bool) -> Bool {
        keychainWriteSucceeded || keychainAlreadyHeldToken
    }

    static func fallbackToDefaults(token: String, keychainWriteSucceeded: Bool) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !keychainWriteSucceeded else { return nil }
        return token
    }
}

enum SessionTokenStore {
    static let defaultsKey = "sessionToken"
    private static let service = "Kikishima"
    private static let account = "session-token"

    static func save(_ token: String, defaults: UserDefaults = .standard) {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return }
#endif
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrote = writeKeychain(trimmed)
        if trimmed.isEmpty || wrote {
            defaults.removeObject(forKey: defaultsKey)
        } else if let fallback = SessionTokenMigration.fallbackToDefaults(token: trimmed, keychainWriteSucceeded: wrote) {
            defaults.set(fallback, forKey: defaultsKey)
        }
    }

    static func load(defaults: UserDefaults = .standard) -> String {
#if SHOOT || DEBUG
        if ShootSimulation.requestedMode != nil { return "" }
#endif
        let decided = SessionTokenMigration.resolve(
            keychain: readKeychain(),
            defaults: defaults.string(forKey: defaultsKey) ?? ""
        )
        var wrote = false
        if let persist = decided.persistKeychain {
            wrote = writeKeychain(persist)
        }
        if SessionTokenMigration.shouldClearDefaults(
            keychainWriteSucceeded: wrote,
            keychainAlreadyHeldToken: decided.persistKeychain == nil && decided.clearDefaultsIfPersisted
        ) {
            defaults.removeObject(forKey: defaultsKey)
        }
        return decided.token
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain() -> String {
        var search = query()
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    private static func writeKeychain(_ token: String) -> Bool {
        SecItemDelete(query() as CFDictionary)
        guard !token.isEmpty else { return true }
        var add = query()
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}
