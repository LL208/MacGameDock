import Foundation

enum SteamResources {
    static func locate(bundleRoots: [URL]) throws -> URL {
        for root in bundleRoots {
            // SwiftPM uses a flat bundle; Xcode uses Contents/Resources.
            var candidates = [root.appendingPathComponent("Resources"),
                              root.appendingPathComponent("Contents/Resources/Resources")]
            if let resources = Bundle(url: root)?.resourceURL {
                candidates.insert(resources.appendingPathComponent("Resources"), at: 0)
            }
            for candidate in candidates {
                let manifest = candidate.appendingPathComponent("helper-files.json")
                let executable = candidate.appendingPathComponent("SteamRuntime/DepotDownloader")
                if FileManager.default.fileExists(atPath: manifest.path),
                   FileManager.default.fileExists(atPath: executable.path) { return candidate }
            }
        }
        throw DockError.message("Motore Steam non trovato nelle risorse dell'app. Usa la build aggiornata o ricompila il progetto.")
    }

    static func current() throws -> URL {
        let name = "MacGameDock_MacGameDock.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent(name)) }
        roots.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent().appendingPathComponent(name))
        }
        // The generated SwiftPM accessor knows Xcode's build-products path.
        // Packaged apps resolve their included bundle without this build-path fallback.
        #if SWIFT_PACKAGE
        if Bundle.main.bundleURL.pathExtension != "app" { roots.append(Bundle.module.bundleURL) }
        #else
        roots.append(Bundle.main.bundleURL)
        #endif
        return try locate(bundleRoots: roots)
    }
}
