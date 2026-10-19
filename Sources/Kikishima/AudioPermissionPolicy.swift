enum AudioPermissionPolicy {
    static func resolve(cachedGranted: Bool, probeSucceeded: Bool) -> (granted: Bool, cacheGranted: Bool) {
        (probeSucceeded, probeSucceeded)
    }
    static func shouldProbeOnForeground(cachedGranted: Bool, probeInFlight: Bool) -> Bool { !probeInFlight }
}
