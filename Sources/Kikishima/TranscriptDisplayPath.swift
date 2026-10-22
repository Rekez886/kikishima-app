import Foundation

/// Abbreviates only the home directory or its descendants for display.
func transcriptDisplayPath(_ directory: URL, homeDirectory: URL) -> String {
    func pathWithoutTrailingSlash(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    let path = pathWithoutTrailingSlash(directory)
    let home = pathWithoutTrailingSlash(homeDirectory)
    if path == home { return "~" }
    let prefix = home == "/" ? "/" : home + "/"
    guard path.hasPrefix(prefix) else { return path }
    return "~/" + path.dropFirst(prefix.count)
}
