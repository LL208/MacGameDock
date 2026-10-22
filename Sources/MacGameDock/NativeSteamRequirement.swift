import Foundation

// The Windows bridge cannot replace the original macOS Steamworks library.
// Keep those versions out of the autonomous launch path instead of starting Steam.
enum NativeSteamRequirement {
    static func windowsSDK(in directory: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in files {
            if ["steam_api.dll", "steam_api64.dll"].contains(file.lastPathComponent.lowercased()) { return true }
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants() }
        }
        return false
    }
    static func originalSDK(in executable: URL) -> Bool {
        let root = executable.pathExtension.lowercased() == "app" ? executable : executable.deletingLastPathComponent()
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants(); continue }
            if ["libsteam_api.dylib", "steam_api.dylib", "steamclient.dylib"].contains(file.lastPathComponent.lowercased()) { return true }
        }
        return false
    }
}
