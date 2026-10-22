import Foundation

struct ScanResult {
    var games: [Game] = []
    var warnings: [String] = []
    // Only roots successfully read can be used to reconcile removed installations.
    var completedSteamApps: Set<String> = []
}

struct InstalledGamesScanner {
    let home: URL
    let fileManager = FileManager.default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func scan(extraRoots: [String]) -> ScanResult {
        var result = ScanResult()
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        var roots = [steam] + extraRoots.map { URL(fileURLWithPath: $0) }
        let folders = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if fileManager.fileExists(atPath: folders.path) {
            do {
                let parsed = try VDF.parse(readText(folders))["libraryfolders"]?.fields ?? [:]
                for (key, value) in parsed where Int(key) != nil {
                    if let path = value.fields?["path"]?.string ?? value.string, path.hasPrefix("/") {
                        roots.append(URL(fileURLWithPath: path))
                    }
                }
            } catch { result.warnings.append("Librerie Steam: \(error.localizedDescription)") }
        }
        var visited: Set<String> = []
        for root in roots {
            let apps = root.lastPathComponent.lowercased() == "steamapps" ? root : root.appendingPathComponent("steamapps")
            guard visited.insert(apps.standardizedFileURL.path).inserted else { continue }
            scanSteam(apps, into: &result)
        }
        let epicRoots = [
            home.appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests"),
            URL(fileURLWithPath: "/Users/Shared/Epic Games/EpicGamesLauncher/Data/Manifests")
        ] + extraRoots.map { URL(fileURLWithPath: $0) }
        for root in epicRoots { scanEpic(root, into: &result) }

        // GOG's offline installers place identifiable app bundles in Applications.
        // Scan only shallow known folders; do not classify arbitrary Mac apps as games.
        let gogRoots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                        home.appendingPathComponent("Games"), URL(fileURLWithPath: "/Applications/GOG Games")]
            + extraRoots.map { URL(fileURLWithPath: $0) }
        for root in gogRoots { scanGOG(root, into: &result) }
        var identities: Set<String> = []
        result.games = result.games.filter { identities.insert($0.identity).inserted }
        return result
    }

    func scanSteam(_ steamApps: URL, into result: inout ScanResult) {
        guard fileManager.fileExists(atPath: steamApps.path) else { return }
        do {
            let files = try fileManager.contentsOfDirectory(at: steamApps, includingPropertiesForKeys: nil)
            var complete = true
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                do {
                    let fields = try VDF.parse(readText(file))["AppState"]?.fields
                    guard let fields, let idText = fields["appid"]?.string, let id = Int(idText), id > 0,
                          let name = fields["name"]?.string, !name.isEmpty,
                          let relative = fields["installdir"]?.string else {
                        throw DockError.message("Manifest Steam incompleto: \(file.lastPathComponent)")
                    }
                    guard let flags = fields["StateFlags"]?.string.flatMap(Int.init), flags & 4 != 0 else { continue }
                    let common = steamApps.appendingPathComponent("common")
                    let location = try safeChild(relative, in: common)
                    guard fileManager.fileExists(atPath: location.path) else { continue }
                    let app = nativeApplication(in: location)
                    result.games.append(Game(id: UUID(), title: name, store: .steam, executablePath: app?.path ?? "", addedAt: Date(),
                                             steamAppID: id, installDirectory: location.path,
                                             launchURL: app == nil ? "steam://rungameid/\(id)" : nil, detectedByScan: true))
                } catch { complete = false; result.warnings.append(error.localizedDescription) }
            }
            if complete { result.completedSteamApps.insert(steamApps.standardizedFileURL.path) }
        } catch { result.warnings.append("Impossibile leggere \(steamApps.path): \(error.localizedDescription)") }
    }

    // Select only an unambiguous valid app bundle; never pick an arbitrary helper executable.
    func nativeApplication(in directory: URL) -> URL? {
        guard let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        var apps: [URL] = []
        for case let file as URL in files {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { files.skipDescendants(); continue }
            guard file.pathExtension.lowercased() == "app" else { continue }
            files.skipDescendants()
            guard let data = try? Data(contentsOf: file.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let executable = info["CFBundleExecutable"] as? String,
                  !executable.contains("/"), executable != "..",
                  fileManager.isExecutableFile(atPath: file.appendingPathComponent("Contents/MacOS/" + executable).path) else { continue }
            apps.append(file)
        }
        return apps.count == 1 ? apps[0] : nil
    }

    func scanEpic(_ root: URL, into result: inout ScanResult) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            let files = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "item" {
                do {
                    let json = try JSONSerialization.jsonObject(with: readData(file)) as? [String: Any]
                    guard let json, let name = json["DisplayName"] as? String,
                          let path = json["InstallLocation"] as? String, path.hasPrefix("/"),
                          let appName = json["AppName"] as? String,
                          json["bIsIncompleteInstall"] as? Bool != true,
                          fileManager.fileExists(atPath: path) else { continue }
                    var components = URLComponents()
                    components.scheme = "com.epicgames.launcher"
                    components.host = "apps"
                    let namespace = json["CatalogNamespace"] as? String ?? ""
                    let catalogID = json["CatalogItemId"] as? String ?? ""
                    let identifier = namespace.isEmpty || catalogID.isEmpty ? appName : "\(namespace):\(catalogID):\(appName)"
                    let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
                    components.percentEncodedPath = "/\(encoded)"
                    components.queryItems = [URLQueryItem(name: "action", value: "launch"), URLQueryItem(name: "silent", value: "true")]
                    result.games.append(Game(id: UUID(), title: name, store: .epic, executablePath: "", addedAt: Date(),
                                             externalID: appName, installDirectory: path,
                                             launchURL: components.url?.absoluteString, detectedByScan: true))
                } catch { result.warnings.append("Manifest Epic \(file.lastPathComponent): \(error.localizedDescription)") }
            }
        } catch { result.warnings.append("Impossibile leggere la cartella Epic: \(error.localizedDescription)") }
    }

    private func scanGOG(_ root: URL, into result: inout ScanResult) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            let children = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            for app in children where app.pathExtension.lowercased() == "app" {
                let infoURL = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? readData(infoURL),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let bundle = info["CFBundleIdentifier"] as? String,
                      bundle.lowercased().hasPrefix("com.gog.") else { continue }
                let title = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
                result.games.append(Game(id: UUID(), title: title, store: .gog, executablePath: app.path, addedAt: Date(),
                                         externalID: bundle, installDirectory: app.path, detectedByScan: true))
            }
            for info in children where info.lastPathComponent.hasPrefix("goggame-") && info.pathExtension == "info" {
                do {
                    guard let json = try JSONSerialization.jsonObject(with: readData(info)) as? [String: Any],
                          let name = json["name"] as? String else { continue }
                    let externalID = (json["gameId"] as? String) ?? info.deletingPathExtension().lastPathComponent
                    let tasks = json["playTasks"] as? [[String: Any]] ?? []
                    let primary = tasks.first { ($0["isPrimary"] as? Bool) == true } ?? tasks.first
                    let relative = primary?["path"] as? String
                    let executable = try relative.map { try safeChild($0.replacingOccurrences(of: "\\", with: "/"), in: root) }
                    // Shell scripts and DOSBox launchers require dedicated integration.
                    guard let executable, ["app", "exe"].contains(executable.pathExtension.lowercased()),
                          fileManager.fileExists(atPath: executable.path) else { continue }
                    result.games.append(Game(id: UUID(), title: name, store: .gog, executablePath: executable.path, addedAt: Date(),
                                             externalID: externalID, installDirectory: root.path, detectedByScan: true))
                } catch { result.warnings.append("Manifest GOG: \(error.localizedDescription)") }
            }
        } catch { result.warnings.append("Impossibile leggere \(root.path): \(error.localizedDescription)") }
    }

    private func readData(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_388_608 else { throw DockError.message("Manifest troppo grande: \(url.lastPathComponent)") }
        return try Data(contentsOf: url)
    }
    private func readText(_ url: URL) throws -> String {
        guard let value = String(data: try readData(url), encoding: .utf8) else {
            throw DockError.message("Manifest non UTF-8: \(url.lastPathComponent)")
        }
        return value
    }
    func safeChild(_ relative: String, in root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              !relative.split(separator: "/").contains(".."), !relative.contains(":") else {
            throw DockError.message("Percorso relativo del gioco non valido.")
        }
        return root.appendingPathComponent(relative).standardizedFileURL
    }
}
