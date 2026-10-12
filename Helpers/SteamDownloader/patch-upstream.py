"""Apply the minimal integration patch to pinned DepotDownloader 3.4.0 sources.
The corresponding modified sources are shipped beside this script.
"""
from pathlib import Path

root = Path(__file__).parent / "Source" / "DepotDownloader"

def replace(name, old, new):
    path = root / name
    text = path.read_text(encoding="utf-8-sig")
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f"Unexpected upstream source: {name}")
    path.write_text(text.replace(old, new), encoding="utf-8")

replace("Steam3Session.cs", "            // Encode the link as a QR code", '''            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MACGAMEDECK_PROTOCOL")))
            {
                DeckIntegration.Emit(new { type = "qr", url = challengeUrl });
                return;
            }
            // Encode the link as a QR code''')

replace("Steam3Session.cs", '            Console.WriteLine(" Done!");\n\n            this.seq++;', '''            if (!DeckIntegration.Account(steamUser.SteamID.ConvertToUInt64().ToString(), logonDetails.Username))
            {
                Abort(false);
                return;
            }
            Console.WriteLine(" Done!");

            this.seq++;''')

replace("ContentDownloader.cs", "            Console.WriteLine();\n\n            try\n            {\n                await DownloadSteam3Async(infos).ConfigureAwait(false);", '''            if (infos.Count != depotIdsFound.Count || infos.Count == 0)
                throw new ContentDownloaderException("Not all required depots are accessible. Installation is incomplete.");

            Console.WriteLine();

            try
            {
                await DownloadSteam3Async(infos).ConfigureAwait(false);
                DeckIntegration.Metadata(appId, GetSteam3AppSection(appId, EAppInfoSection.Common),
                    GetSteam3AppSection(appId, EAppInfoSection.Config), Config.InstallDirectory);''')

replace("Program.cs", "            var appId = GetParameter(args, \"-app\", ContentDownloader.INVALID_APP_ID);", '''            var libraryFile = GetParameter<string>(args, "-deck-library");
            if (libraryFile != null)
            {
                if (!InitializeSteam(username, password)) return 1;
                try { await ContentDownloader.ExportDeckLibraryAsync(libraryFile); return 0; }
                catch (Exception) { Console.WriteLine("Unable to load the authenticated Steam library."); return 1; }
                finally { ContentDownloader.ShutdownSteam3(); }
            }
            var appId = GetParameter(args, "-app", ContentDownloader.INVALID_APP_ID);''')

replace("ContentDownloader.cs", "        public static void ShutdownSteam3()", '''        public static async Task ExportDeckLibraryAsync(string destination)
        {
            for (var i = 0; steam3.Licenses == null && i < 300; i++) await Task.Delay(200);
            if (steam3.Licenses == null) throw new ContentDownloaderException("Steam licenses unavailable.");
            var packageIDs = steam3.Licenses.Select(x => x.PackageID).Distinct().ToList();
            await steam3.RequestPackageInfo(packageIDs);
            var appIDs = packageIDs.Where(id => steam3.PackageInfo.ContainsKey(id) && steam3.PackageInfo[id] != null)
                .SelectMany(id => steam3.PackageInfo[id].KeyValues["appids"].Children.Select(x => x.AsUnsignedInteger()))
                .Distinct().Where(id => id > 0).ToList();
            var games = new List<object>();
            for (var start = 0; start < appIDs.Count; start += 100)
            {
                await steam3.RequestDeckAppInfos(appIDs.Skip(start).Take(100).ToArray());
                foreach (var id in appIDs.Skip(start).Take(100))
                {
                    var common = GetSteam3AppSection(id, EAppInfoSection.Common);
                    var type = common?["type"].AsString()?.ToLowerInvariant();
                    if (type == "game" || type == "demo" || type == "mod")
                        games.Add(new { appid = id, name = common["name"].AsString() });
                }
                DeckIntegration.Emit(new { type = "library_progress", done = Math.Min(start + 100, appIDs.Count), total = appIDs.Count });
            }
            var steamID = steam3.steamUser.SteamID.ConvertToUInt64().ToString();
            File.WriteAllText(destination, System.Text.Json.JsonSerializer.Serialize(new { steamID, games }));
            DeckIntegration.Emit(new { type = "library_complete", count = games.Count });
        }

        public static void ShutdownSteam3()''')

replace("Steam3Session.cs", "        public async Task RequestPackageInfo(IEnumerable<uint> packageIds)", '''        public async Task RequestDeckAppInfos(uint[] appIDs)
        {
            var tokens = await steamApps.PICSGetAccessTokens(appIDs, []);
            var requests = appIDs.Select(id => {
                var request = new SteamApps.PICSRequest(id);
                if (tokens.AppTokens.TryGetValue(id, out var token)) request.AccessToken = token;
                return request;
            }).ToArray();
            var results = await steamApps.PICSGetProductInfo(requests, []);
            foreach (var result in results.Results)
            {
                foreach (var app in result.Apps) AppInfo[app.Key] = app.Value;
                foreach (var id in result.UnknownApps) AppInfo[id] = null;
            }
        }

        public async Task RequestPackageInfo(IEnumerable<uint> packageIds)''')

# Keep refresh tokens only in the app's private working directory; Swift moves
# this file to Keychain and removes the directory when the process exits.
replace("AccountSettingsStore.cs", "        static readonly IsolatedStorageFile IsolatedStorage = IsolatedStorageFile.GetUserStoreForAssembly();", "        // MacGameDeck supplies a private, temporary working directory.")
replace("AccountSettingsStore.cs", "IsolatedStorage.FileExists(filename)", "File.Exists(filename)")
replace("AccountSettingsStore.cs", "IsolatedStorage.OpenFile(filename, FileMode.Open, FileAccess.Read)", "File.Open(filename, FileMode.Open, FileAccess.Read)")
replace("AccountSettingsStore.cs", "IsolatedStorage.OpenFile(Instance.FileName, FileMode.Create, FileAccess.Write)", "File.Open(Instance.FileName, FileMode.Create, FileAccess.Write)")
replace("ContentDownloader.cs", "            await steam3.RequestPackageInfo(packageIDs);", '''            await steam3.RequestPackageInfo(packageIDs);
            if (packageIDs.Any(id => !steam3.PackageInfo.ContainsKey(id) || steam3.PackageInfo[id] == null))
                throw new ContentDownloaderException("Incomplete package metadata; preserving the previous library.");''')
replace("ContentDownloader.cs", "                Ansi.Progress(downloadCounter.totalBytesUncompressed, downloadCounter.completeDownloadSize);", '''                Ansi.Progress(downloadCounter.totalBytesUncompressed, downloadCounter.completeDownloadSize);
                DeckIntegration.Progress(downloadCounter.totalBytesUncompressed, downloadCounter.completeDownloadSize);''')

# Name shown in the Steam Guard authorization screen.
p = root / "Steam3Session.cs"
p.write_text(p.read_text().replace("DeviceFriendlyName = nameof(DepotDownloader)", 'DeviceFriendlyName = "MacGameDeck"'))
