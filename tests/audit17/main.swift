import Foundation
let revoked = AudioPermissionPolicy.resolve(cachedGranted: true, probeSucceeded: false)
precondition(!revoked.granted && !revoked.cacheGranted,
    "audit17: failed foreground probe must revoke displayed and cached grant")
let denied = AudioPermissionPolicy.resolve(cachedGranted: false, probeSucceeded: false)
precondition(!denied.granted && !denied.cacheGranted, "audit17: denial cannot grant permission")
for cache in [false, true] {
    let allowed = AudioPermissionPolicy.resolve(cachedGranted: cache, probeSucceeded: true)
    precondition(allowed.granted && allowed.cacheGranted, "audit17: successful probe grants and updates cache")
}
precondition(AudioPermissionPolicy.shouldProbeOnForeground(cachedGranted: true, probeInFlight: false),
    "audit17: cached grant must not bypass foreground revalidation")
precondition(!AudioPermissionPolicy.shouldProbeOnForeground(cachedGranted: true, probeInFlight: true),
    "audit17: do not overlap probes")
print("PASS audit17 permission revalidation")
