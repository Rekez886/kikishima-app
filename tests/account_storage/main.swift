import Foundation

// Localization is unrelated to storage; Translator is compiled but never started.
func trAny(_ text: String, _ arguments: CVarArg...) -> String { text }

#if DEBUG || SHOOT
// This test binary never constructs CaptionState or the simulation UI.
enum ShootSimulation { static var requestedMode: Bool? }
#endif

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

// No real preference domain, Keychain item, legacy file or network is accessed.
final class MemoryDefaults: UserDefaults {
    var values: [String: String] = [:]
    var reads = 0
    var writes = 0
    override func string(forKey defaultName: String) -> String? {
        reads += 1
        return values[defaultName]
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        values[defaultName] = value as? String
    }
    override func removeObject(forKey defaultName: String) {
        writes += 1
        values.removeValue(forKey: defaultName)
    }
}

final class MemoryKeychain {
    struct Item: Hashable { var service: String; var account: String }
    var values: [Item: String] = [:]
    var touched: [Item] = []
    var writesSucceed = true
    var backend: CredentialKeychain {
        CredentialKeychain(read: { service, account in
            let item = Item(service: service, account: account)
            self.touched.append(item)
            return self.values[item] ?? ""
        }, write: { service, account, value in
            let item = Item(service: service, account: account)
            self.touched.append(item)
            guard self.writesSucceed else { return false }
            self.values[item] = value.isEmpty ? nil : value
            return true
        })
    }
    func item(_ scope: CredentialScope, _ account: String = "session-token") -> Item {
        Item(service: scope.keychainService, account: account)
    }
}

let defaults = MemoryDefaults()
let vault = MemoryKeychain()
let production = CredentialScope.resolve(bundleID: "com.kikishima.mac", build: .release, simulation: false)
let debug = CredentialScope.resolve(bundleID: "com.kikishima.mac", build: .debug, simulation: false)
let shoot = CredentialScope.resolve(bundleID: "com.kikishima.mac", build: .shoot, simulation: false)
let testRelease = CredentialScope.resolve(bundleID: "com.kikishima.mac.r11test", build: .release, simulation: false)
let isolated = [debug, shoot, testRelease,
    CredentialScope.resolve(bundleID: nil, build: .release, simulation: false),
    CredentialScope.resolve(bundleID: "", build: .release, simulation: false),
    CredentialScope.resolve(bundleID: "unbundled", build: .release, simulation: false)]
check(production == .production, "the installed release keeps its legacy namespace")
check(production.keychainService == "Kikishima", "production Keychain service stays compatible")
check(production.defaultsKey("sessionToken") == "sessionToken", "production plaintext migration key stays compatible")
check(Set(isolated.map(\.keychainService)).count == isolated.count, "build, bundle, nil and empty namespaces are distinct")
check(Set(isolated.map { $0.defaultsKey("sessionToken") }).count == isolated.count, "preference namespaces are distinct")
for id in ["com.test.a-b", "com.test.a_b", "com.test.A-b", "com.test.a.b", "bundle.", ""] {
    let a = CredentialScope.resolve(bundleID: id, build: .debug, simulation: false)
    let b = CredentialScope.resolve(bundleID: id + ".", build: .debug, simulation: false)
    check(a.keychainService != b.keychainService, "bundle identity is not normalized destructively")
}
for build in [CredentialScope.Build.release, .debug, .shoot] {
    check(CredentialScope.resolve(bundleID: "com.kikishima.mac", build: build, simulation: true) == .disabled,
          "simulations disable every storage channel")
}

// Verify the actual compiled build, including release/DEBUG apps packaged by the runner.
#if SHOOT
let compiledBuild = CredentialScope.Build.shoot
#elseif DEBUG
let compiledBuild = CredentialScope.Build.debug
#else
let compiledBuild = CredentialScope.Build.release
#endif
check(CredentialScope.current == CredentialScope.resolve(bundleID: Bundle.main.bundleIdentifier,
    build: compiledBuild, simulation: false), "the compiled build selects the intended scope")
if CommandLine.arguments.count > 1 {
    check(Bundle.main.bundleIdentifier == CommandLine.arguments[1], "the test fixture really has its declared bundle ID")
}
#if DEBUG || SHOOT
ShootSimulation.requestedMode = true
check(CredentialScope.current == .disabled, "the real simulation selector disables persistence")
ShootSimulation.requestedMode = nil
#endif

// Seed ONLY fake production credentials. Test launch, login, restart and logout
// must neither read nor mutate them, even with a shared UserDefaults domain.
defaults.values["sessionToken"] = "fake-production-legacy"
vault.values[vault.item(production)] = "fake-production-session"
vault.values[vault.item(production, "openai-key")] = "fake-production-api-key"
let accountKeys = ["plan", "planExpires", "accountEmail", "installID", "activationId"]
for key in accountKeys { defaults.values[key] = "fake-production-" + key }
let productionDefaults = defaults.values
let productionKeychain = vault.values
var legacyReads = 0, legacyRemoves = 0
var legacyValue = "fake-legacy-api-key"
let legacy = Keychain.LegacyFile(read: { legacyReads += 1; return legacyValue },
                                remove: { legacyRemoves += 1; legacyValue = "" })
for scope in isolated {
    let initialCalls = vault.touched.count
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend).isEmpty,
          "isolated startup cannot import the production session")
    for key in accountKeys {
        check(AccountPreferences.string(forKey: key, defaults: defaults, scope: scope) == nil,
              "isolated startup cannot import production account metadata")
        AccountPreferences.set("fake-test-" + key, forKey: key, defaults: defaults, scope: scope)
        check(AccountPreferences.string(forKey: key, defaults: defaults, scope: scope) == "fake-test-" + key,
              "test account metadata persists only in its own namespace")
    }
    SessionTokenStore.save(" fake-test-session \n", defaults: defaults, scope: scope, keychain: vault.backend)
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend) == "fake-test-session",
          "isolated login survives a reload")
    check(Keychain.loadKey(scope: scope, keychain: vault.backend, legacy: legacy).isEmpty,
          "isolated BYO startup cannot import production keys or legacy files")
    Keychain.saveKey(" fake-test-key \n", scope: scope, keychain: vault.backend, legacy: legacy)
    check(Keychain.loadKey(scope: scope, keychain: vault.backend, legacy: legacy) == "fake-test-key",
          "isolated BYO credentials survive a reload")
    SessionTokenStore.save("", defaults: defaults, scope: scope, keychain: vault.backend)
    Keychain.saveKey("", scope: scope, keychain: vault.backend, legacy: legacy)
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend).isEmpty,
          "test logout clears the test token")
    check(Keychain.loadKey(scope: scope, keychain: vault.backend, legacy: legacy).isEmpty,
          "test key removal clears only the test key")
    for key in accountKeys { AccountPreferences.set(nil, forKey: key, defaults: defaults, scope: scope) }
    check(vault.touched.dropFirst(initialCalls).allSatisfy { $0.service == scope.keychainService },
          "every test Keychain read and write stays in its namespace")
    check(defaults.values == productionDefaults, "test login/logout leaves all production preferences untouched")
    check(vault.values == productionKeychain, "test login/logout leaves all production credentials untouched")
    check(legacyReads == 0 && legacyRemoves == 0, "test BYO never reads, migrates or removes the legacy file")
}

// Isolation also applies when Keychain access fails and plaintext fallback is needed.
vault.writesSucceed = false
SessionTokenStore.save("fake-test-fallback", defaults: defaults, scope: debug, keychain: vault.backend)
check(defaults.values[debug.defaultsKey("sessionToken")] == "fake-test-fallback", "failed write keeps only the scoped fallback")
check(SessionTokenStore.load(defaults: defaults, scope: debug, keychain: vault.backend) == "fake-test-fallback",
      "failed migration preserves the scoped fallback")
check(defaults.values["sessionToken"] == productionDefaults["sessionToken"], "failed migration never modifies the production fallback")
vault.writesSucceed = true
check(SessionTokenStore.load(defaults: defaults, scope: debug, keychain: vault.backend) == "fake-test-fallback",
      "later successful migration recovers the same test session")
check(defaults.values[debug.defaultsKey("sessionToken")] == nil, "successful migration removes only its own fallback")
check(vault.values[vault.item(production)] == "fake-production-session", "test migration does not replace the production token")
SessionTokenStore.save("", defaults: defaults, scope: debug, keychain: vault.backend)

// A failed account replacement must not combine new metadata with an old token.
for scope in [production, debug, shoot, testRelease] {
    SessionTokenStore.save("fake-old-account", defaults: defaults, scope: scope, keychain: vault.backend)
    vault.writesSucceed = false
    SessionTokenStore.save("fake-new-account", defaults: defaults, scope: scope, keychain: vault.backend)
    check(vault.values[vault.item(scope)] == "fake-old-account", "failed replacement preserves the existing Keychain item")
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend) == "fake-new-account",
          "pending replacement wins over the stale Keychain account")
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend) == "fake-new-account",
          "another launch does not lose the pending replacement")
    vault.writesSucceed = true
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend) == "fake-new-account",
          "recovered Keychain accepts the pending replacement")
    check(vault.values[vault.item(scope)] == "fake-new-account", "recovered replacement becomes durable")
    check(defaults.values[scope.defaultsKey("sessionToken")] == nil, "recovered replacement clears the plaintext fallback")
    check(defaults.values[scope.defaultsKey("sessionTokenPendingWrite")] == nil, "recovered replacement clears its marker")

    vault.writesSucceed = false
    SessionTokenStore.save("", defaults: defaults, scope: scope, keychain: vault.backend)
    check(vault.values[vault.item(scope)] == "fake-new-account", "failed deletion can leave an inaccessible Keychain token")
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend).isEmpty,
          "failed deletion never signs the user back in")
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend).isEmpty,
          "sign-out survives repeated launches while Keychain is unavailable")
    vault.writesSucceed = true
    check(SessionTokenStore.load(defaults: defaults, scope: scope, keychain: vault.backend).isEmpty,
          "sign-out retries cleanup when Keychain recovers")
    check(vault.values[vault.item(scope)] == nil, "recovered sign-out removes the old Keychain token")
    check(defaults.values[scope.defaultsKey("sessionTokenPendingWrite")] == nil, "recovered sign-out clears its marker")
}
vault.values[vault.item(production)] = "fake-production-session"
defaults.values["sessionToken"] = "fake-production-legacy"

// Simulations must return before any backend or preferences access.
let readsBefore = defaults.reads, writesBefore = defaults.writes, callsBefore = vault.touched.count
check(SessionTokenStore.load(defaults: defaults, scope: .disabled, keychain: vault.backend).isEmpty, "simulation session is empty")
SessionTokenStore.save("fake-simulation", defaults: defaults, scope: .disabled, keychain: vault.backend)
for key in accountKeys {
    check(AccountPreferences.string(forKey: key, defaults: defaults, scope: .disabled) == nil, "simulation metadata is empty")
    AccountPreferences.set("fake-simulation", forKey: key, defaults: defaults, scope: .disabled)
}
check(Keychain.loadKey(scope: .disabled, keychain: vault.backend, legacy: legacy).isEmpty, "simulation API key is empty")
Keychain.saveKey("fake-simulation", scope: .disabled, keychain: vault.backend, legacy: legacy)
check(KeychainStore.loadKey(scope: .disabled, keychain: vault.backend).isEmpty, "direct simulation Keychain reads are blocked")
check(!KeychainStore.saveKey("fake-simulation", scope: .disabled, keychain: vault.backend), "direct simulation Keychain writes are blocked")
check(defaults.reads == readsBefore && defaults.writes == writesBefore && vault.touched.count == callsBefore,
      "simulations never touch persistence")
check(legacyReads == 0 && legacyRemoves == 0, "simulations never resolve the legacy file")

// Production compatibility, exercised entirely with the same in-memory doubles.
check(SessionTokenStore.load(defaults: defaults, scope: production, keychain: vault.backend) == "fake-production-session",
      "production Keychain still wins over its stale fallback")
check(defaults.values["sessionToken"] == nil, "production clears a stale legacy fallback")
vault.values.removeValue(forKey: vault.item(production))
defaults.values["sessionToken"] = " fake-production-migrate \n"
check(SessionTokenStore.load(defaults: defaults, scope: production, keychain: vault.backend) == "fake-production-migrate",
      "production still migrates its legacy session")
check(vault.values[vault.item(production)] == "fake-production-migrate", "production migration uses the existing Keychain identity")
for key in accountKeys {
    check(AccountPreferences.string(forKey: key, defaults: defaults, scope: production) == "fake-production-" + key,
          "production account metadata is not reset")
}
check(Keychain.loadKey(scope: production, keychain: vault.backend, legacy: legacy) == "fake-production-api-key",
      "production still reads the existing BYO key")
check(legacyRemoves == 1 && legacyReads == 0, "production removes only its stale legacy file")
vault.values.removeValue(forKey: vault.item(production, "openai-key"))
legacyValue = " fake-legacy-api-key \n"
vault.writesSucceed = false
check(Keychain.loadKey(scope: production, keychain: vault.backend, legacy: legacy) == "fake-legacy-api-key",
      "failed production BYO migration preserves its usable fallback")
check(legacyRemoves == 1, "failed production migration does not delete the fallback")
vault.writesSucceed = true
check(Keychain.loadKey(scope: production, keychain: vault.backend, legacy: legacy) == "fake-legacy-api-key",
      "production BYO migration can recover later")
check(legacyRemoves == 2 && legacyValue.isEmpty, "successful production BYO migration cleans its own fallback")

// A background summary load repairing a pending token must finish before a
// later login/sign-out transaction. Otherwise its old token can overwrite the
// new account or resurrect an explicitly signed-out session.
for replacement in ["fake-later-account", ""] {
    let raceDefaults = MemoryDefaults()
    let raceVault = MemoryKeychain()
    raceDefaults.values[debug.defaultsKey("sessionToken")] = "fake-pending-account"
    raceDefaults.values[debug.defaultsKey("sessionTokenPendingWrite")] = "replace"
    let loadEntered = DispatchSemaphore(value: 0), releaseLoad = DispatchSemaphore(value: 0)
    let loadFinished = DispatchSemaphore(value: 0), saveStarted = DispatchSemaphore(value: 0)
    let saveFinished = DispatchSemaphore(value: 0)
    let ordinary = raceVault.backend
    let delayed = CredentialKeychain(read: ordinary.read, write: { service, account, value in
        if value == "fake-pending-account" {
            loadEntered.signal()
            precondition(releaseLoad.wait(timeout: .now() + 5) == .success, "test did not release the blocked load")
        }
        return ordinary.write(service, account, value)
    })
    DispatchQueue.global().async {
        _ = SessionTokenStore.load(defaults: raceDefaults, scope: debug, keychain: delayed)
        loadFinished.signal()
    }
    check(loadEntered.wait(timeout: .now() + 5) == .success, "the old pending load has started its write")
    DispatchQueue.global().async {
        saveStarted.signal()
        SessionTokenStore.save(replacement, defaults: raceDefaults, scope: debug, keychain: delayed)
        saveFinished.signal()
    }
    check(saveStarted.wait(timeout: .now() + 5) == .success, "the newer account operation was scheduled")
    check(saveFinished.wait(timeout: .now() + 0.1) == .timedOut, "newer operation waits for the entire older transaction")
    releaseLoad.signal()
    check(loadFinished.wait(timeout: .now() + 5) == .success, "the older load can finish")
    check(saveFinished.wait(timeout: .now() + 5) == .success, "the newer operation runs after the older load")
    check(SessionTokenStore.load(defaults: raceDefaults, scope: debug, keychain: ordinary) == replacement,
          "the last login/sign-out wins after a concurrent repair")
    check(raceDefaults.values.isEmpty, "completed concurrent operations leave no stale fallback or pending marker")
}

print("PASS: \(checks) account storage checks (\(compiledBuild.rawValue), bundle \(Bundle.main.bundleIdentifier ?? "unbundled")); fake storage only")
