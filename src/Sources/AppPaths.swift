import Foundation

/// AppPaths resolves bundled binaries/resources and the on-disk state dir,
/// working both for `swift run` (SwiftPM resource bundle) and the packaged
/// .app (Contents/Resources), exactly like VibeProxy must.
enum AppPaths {
    /// State directory shared with the router (~/.vibeshare).
    static var stateDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".vibeshare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Locates a bundled resource by name. Works for the packaged .app (files in
    /// Contents/Resources) and, in non-packaged development builds, for the
    /// SwiftPM resource bundle.
    ///
    /// CRITICAL: packaged app builds define PACKAGED_APP so they never compile a
    /// reference to `Bundle.module`. SwiftPM's generated accessor embeds an
    /// absolute development bundle path, which leaks the local username into
    /// strings output even if the app never reaches that branch at runtime.
    static func resource(_ name: String) -> URL? {
        let fm = FileManager.default

        // 1. Packaged .app — files copied straight into Contents/Resources.
        if let r = Bundle.main.resourceURL?.appendingPathComponent(name),
           fm.fileExists(atPath: r.path) {
            return r
        }
        if let u = Bundle.main.url(forResource: name, withExtension: nil) {
            return u
        }

        // 2. Beside the executable (defensive).
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for c in [exeDir.appendingPathComponent(name),
                      exeDir.appendingPathComponent("Resources").appendingPathComponent(name)] {
                if fm.fileExists(atPath: c.path) { return c }
            }
        }

        #if !PACKAGED_APP
        // 3. Dev only — the SwiftPM `.copy("Resources")` bundle.
        if let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") {
            return u
        }
        return Bundle.module.url(forResource: name, withExtension: nil)
        #else
        return nil
        #endif
    }

    static var routerBinary: URL? { resource("vibeshare-router") }
    static var providerBinary: URL? { resource("cli-proxy-api-plus") }

    /// Ensures a writable cli-proxy-api config exists and returns its path.
    static func providerConfigPath() -> URL {
        let dest = stateDir.appendingPathComponent("cli-proxy-config.yaml")
        if !FileManager.default.fileExists(atPath: dest.path),
           let bundled = resource("config.yaml") {
            try? FileManager.default.copyItem(at: bundled, to: dest)
        }
        return dest
    }

    /// Ensures cli-proxy-api's auth dir exists.
    static var providerAuthDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
