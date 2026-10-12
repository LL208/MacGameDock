import Foundation

enum LibraryMerge {
    static func scan(_ result: ScanResult, into original: LibraryData) -> LibraryData {
        var data = original
        let found = Set(result.games.map(\.identity))
        data.games = data.games.compactMap { game in
            guard game.detectedByScan == true, game.store == .steam, !found.contains(game.identity),
                  let installation = game.installDirectory,
                  result.completedSteamApps.contains(where: { installation.hasPrefix($0 + "/common/") }) else { return game }
            guard game.catalogOwner != nil else { return nil }
            var updated = game
            updated.installDirectory = nil
            updated.launchURL = nil
            updated.executablePath = ""
            updated.detectedByScan = nil
            return updated
        }
        for foundGame in result.games {
            if let index = data.games.firstIndex(where: { $0.identity == foundGame.identity ||
                (!$0.executablePath.isEmpty && $0.executablePath == foundGame.executablePath) }) {
                if data.games[index].managedLaunch != nil { continue }
                var existing = data.games[index]
                existing.title = foundGame.title
                existing.store = foundGame.store
                existing.steamAppID = foundGame.steamAppID
                existing.externalID = foundGame.externalID
                existing.installDirectory = foundGame.installDirectory
                existing.launchURL = foundGame.launchURL
                if !foundGame.executablePath.isEmpty { existing.executablePath = foundGame.executablePath }
                existing.detectedByScan = true
                data.games[index] = existing
            } else { data.games.append(foundGame) }
        }
        return data
    }

    static func ownedGames(_ owned: [SteamOwnedGame], owner: String, into original: LibraryData, now: Date = Date()) -> LibraryData {
        var data = original
        let appIDs = Set(owned.map(\.appid))
        // Reconcile the cloud snapshot while retaining local installations and manual imports.
        data.games = data.games.compactMap { game in
            guard let previousOwner = game.catalogOwner else { return game }
            if previousOwner == owner, let id = game.steamAppID, appIDs.contains(id) { return game }
            guard game.isInstalled || game.detectedByScan == true else { return nil }
            var local = game
            local.catalogOwner = nil
            return local
        }
        for item in owned {
            if let index = data.games.firstIndex(where: { $0.steamAppID == item.appid && $0.store == .steam }) {
                data.games[index].catalogOwner = owner
                if let name = item.name, !name.isEmpty { data.games[index].title = name }
            } else {
                data.games.append(Game(id: UUID(), title: item.name ?? "Gioco Steam \(item.appid)", store: .steam,
                                       executablePath: "", addedAt: now, steamAppID: item.appid, catalogOwner: owner))
            }
        }
        data.steamLibrarySyncedAt = now
        return data
    }

    static func disconnect(_ original: LibraryData) -> LibraryData {
        var data = original
        data.steamAccount = nil
        data.steamLibrarySyncedAt = nil
        data.games = data.games.compactMap { game in
            guard game.catalogOwner != nil else { return game }
            guard game.isInstalled || game.detectedByScan == true else { return nil }
            var local = game
            local.catalogOwner = nil
            return local
        }
        return data
    }
}
