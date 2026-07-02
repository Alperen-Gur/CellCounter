import Foundation

/// Persists security-scoped bookmarks to user-chosen folders/files so the
/// sandboxed app keeps access across launches. Stored in UserDefaults under
/// the caller-supplied key as `Data`.
enum SecurityBookmarks {

    /// Create and store an app-scope, security-scoped bookmark for `url`.
    /// Safe to call from the same context that just received the open-panel URL.
    static func save(_ url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // If bookmark creation fails (e.g. user picked something we can't bookmark),
            // remove any stale entry so resolve() returns nil rather than a broken handle.
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Resolve the previously-stored bookmark and start security-scoped access.
    /// The caller MUST balance this with `stop(_:)` once the read/write is done.
    /// Returns nil if no bookmark stored, resolution failed, or access denied.
    static func resolve(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // Refresh stale bookmarks so they keep working next launch.
            if isStale {
                save(url, key: key)
            }
            guard url.startAccessingSecurityScopedResource() else { return nil }
            return url
        } catch {
            return nil
        }
    }

    /// Matching stop for `resolve(_:)`. No-op for nil.
    static func stop(_ url: URL?) {
        url?.stopAccessingSecurityScopedResource()
    }
}
