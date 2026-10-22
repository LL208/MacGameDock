// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using QRCoder;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.CDN;
using SteamKit2.Internal;

namespace DepotDownloader
{
    partial class Steam3Session
    {
        public bool IsLoggedOn { get; private set; }

        public ReadOnlyCollection<SteamApps.LicenseListCallback.License> Licenses
        {
            get;
            private set;
        }

        public Dictionary<uint, ulong> AppTokens { get; } = [];
        public Dictionary<uint, ulong> PackageTokens { get; } = [];
        public Dictionary<uint, byte[]> DepotKeys { get; } = [];
        public ConcurrentDictionary<(uint, string), TaskCompletionSource<SteamContent.CDNAuthToken>> CDNAuthTokens { get; } = [];
        public Dictionary<uint, SteamApps.PICSProductInfoCallback.PICSProductInfo> AppInfo { get; } = [];
        public Dictionary<uint, SteamApps.PICSProductInfoCallback.PICSProductInfo> PackageInfo { get; } = [];
        public Dictionary<string, byte[]> AppBetaPasswords { get; } = [];

        public SteamClient steamClient;
        public SteamUser steamUser;
        public SteamContent steamContent;
        readonly SteamApps steamApps;
        readonly SteamCloud steamCloud;
        readonly PublishedFile steamPublishedFile;

        readonly CallbackManager callbacks;

        readonly bool authenticatedUser;
        bool bConnecting;
        bool bAborted;
        bool bExpectingDisconnectRemote;
        bool bDidDisconnect;
        bool bIsConnectionRecovery;
        int connectionBackoff;
        int seq; // more hack fixes
        AuthSession authSession;
        readonly CancellationTokenSource abortedToken = new();

        // input
        readonly SteamUser.LogOnDetails logonDetails;

        public Steam3Session(SteamUser.LogOnDetails details)
        {
            this.logonDetails = details;
            this.authenticatedUser = details.Username != null || ContentDownloader.Config.UseQrCode;

            var clientConfiguration = SteamConfiguration.Create(config => {
                config.WithHttpClientFactory(HttpClientFactory.CreateHttpClient);
                var machine = Environment.GetEnvironmentVariable("MACGAMEDECK_MACHINE_ID");
                if (!string.IsNullOrEmpty(machine)) config.WithMachineInfoProvider(new DeckMachineInfoProvider(machine));
            });

            this.steamClient = new SteamClient(clientConfiguration);

            this.steamUser = this.steamClient.GetHandler<SteamUser>();
            this.steamApps = this.steamClient.GetHandler<SteamApps>();
            this.steamCloud = this.steamClient.GetHandler<SteamCloud>();
            var steamUnifiedMessages = this.steamClient.GetHandler<SteamUnifiedMessages>();
            this.steamPublishedFile = steamUnifiedMessages.CreateService<PublishedFile>();
            this.steamContent = this.steamClient.GetHandler<SteamContent>();

            this.callbacks = new CallbackManager(this.steamClient);

            this.callbacks.Subscribe<SteamClient.ConnectedCallback>(ConnectedCallback);
            this.callbacks.Subscribe<SteamClient.DisconnectedCallback>(DisconnectedCallback);
            this.callbacks.Subscribe<SteamUser.LoggedOnCallback>(LogOnCallback);
            this.callbacks.Subscribe<SteamApps.LicenseListCallback>(LicenseListCallback);

            Console.Write("Connecting to Steam3...");
            Connect();
        }

        public delegate bool WaitCondition();

        private readonly Lock steamLock = new();

        public bool WaitUntilCallback(Action submitter, WaitCondition waiter)
        {
            while (!bAborted && !waiter())
            {
                lock (steamLock)
                {
                    submitter();
                }

                var seq = this.seq;
                do
                {
                    lock (steamLock)
                    {
                        callbacks.RunWaitCallbacks(TimeSpan.FromSeconds(1));
                    }
                } while (!bAborted && this.seq == seq && !waiter());
            }

            return bAborted;
        }

        public bool WaitForCredentials()
        {
            if (IsLoggedOn || bAborted)
                return IsLoggedOn;

            WaitUntilCallback(() => { }, () => IsLoggedOn);

            return IsLoggedOn;
        }

        public async Task TickCallbacks()
        {
            var token = abortedToken.Token;

            try
            {
                while (!token.IsCancellationRequested)
                {
                    await callbacks.RunWaitCallbackAsync(token);
                }
            }
            catch (OperationCanceledException)
            {
                //
            }
        }

        public async Task RequestAppInfo(uint appId, bool bForce = false)
        {
            if ((AppInfo.ContainsKey(appId) && !bForce) || bAborted)
                return;

            var appTokens = await steamApps.PICSGetAccessTokens([appId], []);

            if (appTokens.AppTokensDenied.Contains(appId))
            {
                Console.WriteLine("Insufficient privileges to get access token for app {0}", appId);
            }

            foreach (var token_dict in appTokens.AppTokens)
            {
                this.AppTokens[token_dict.Key] = token_dict.Value;
            }

            var request = new SteamApps.PICSRequest(appId);

            if (AppTokens.TryGetValue(appId, out var token))
            {
                request.AccessToken = token;
            }

            var appInfoMultiple = await steamApps.PICSGetProductInfo([request], []);

            foreach (var appInfo in appInfoMultiple.Results)
            {
                foreach (var app_value in appInfo.Apps)
                {
                    var app = app_value.Value;

                    Console.WriteLine("Got AppInfo for {0}", app.ID);
                    AppInfo[app.ID] = app;
                }

                foreach (var app in appInfo.UnknownApps)
                {
                    AppInfo[app] = null;
                }
            }
        }

        public async Task<List<CFamilyGroups_GetSharedLibraryApps_Response.SharedApp>> DeckFamilyApps()
        {
            var service = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<FamilyGroups>();
            var group = await service.GetFamilyGroupForUser(new CFamilyGroups_GetFamilyGroupForUser_Request
            {
                steamid = steamUser.SteamID.ConvertToUInt64()
            });
            if (group.Result != EResult.OK) throw new Exception("Steam family information unavailable.");
            if (group.Body.is_not_member_of_any_group || group.Body.family_groupid == 0) return [];
            var apps = await service.GetSharedLibraryApps(new CFamilyGroups_GetSharedLibraryApps_Request
            {
                family_groupid = group.Body.family_groupid,
                steamid = steamUser.SteamID.ConvertToUInt64(),
                include_own = true, include_excluded = false, include_non_games = false, language = "italian"
            });
            if (apps.Result != EResult.OK) throw new Exception("Steam family library unavailable.");
            return apps.Body.apps;
        }

        public async Task RequestDeckAppInfos(uint[] appIDs)
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

        public async Task RequestPackageInfo(IEnumerable<uint> packageIds)
        {
            var packages = packageIds.ToList();
            packages.RemoveAll(PackageInfo.ContainsKey);

            if (packages.Count == 0 || bAborted)
                return;

            var packageRequests = new List<SteamApps.PICSRequest>();

            foreach (var package in packages)
            {
                var request = new SteamApps.PICSRequest(package);

                if (PackageTokens.TryGetValue(package, out var token))
                {
                    request.AccessToken = token;
                }

                packageRequests.Add(request);
            }

            var packageInfoMultiple = await steamApps.PICSGetProductInfo([], packageRequests);

            foreach (var packageInfo in packageInfoMultiple.Results)
            {
                foreach (var package_value in packageInfo.Packages)
                {
                    var package = package_value.Value;
                    PackageInfo[package.ID] = package;
                }

                foreach (var package in packageInfo.UnknownPackages)
                {
                    PackageInfo[package] = null;
                }
            }
        }

        public async Task<bool> RequestFreeAppLicense(uint appId)
        {
            try
            {
                var resultInfo = await steamApps.RequestFreeLicense(appId);

                return resultInfo.GrantedApps.Contains(appId);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to request FreeOnDemand license for app {appId}: {ex.Message}");
                return false;
            }
        }

        public async Task RequestDepotKey(uint depotId, uint appid = 0)
        {
            if (DepotKeys.ContainsKey(depotId) || bAborted)
                return;

            var depotKey = await steamApps.GetDepotDecryptionKey(depotId, appid);

            Console.WriteLine("Got depot key for {0} result: {1}", depotKey.DepotID, depotKey.Result);

            if (depotKey.Result != EResult.OK)
            {
                return;
            }

            DepotKeys[depotKey.DepotID] = depotKey.DepotKey;
        }


        public async Task<ulong> GetDepotManifestRequestCodeAsync(uint depotId, uint appId, ulong manifestId, string branch)
        {
            if (bAborted)
                return 0;

            var requestCode = await steamContent.GetManifestRequestCode(depotId, appId, manifestId, branch);

            if (requestCode == 0)
            {
                Console.WriteLine($"No manifest request code was returned for depot {depotId} from app {appId}, manifest {manifestId}");

                if (!authenticatedUser)
                {
                    Console.WriteLine("Suggestion: Try logging in with -username as old manifests may not be available for anonymous accounts.");
                }
            }
            else
            {
                Console.WriteLine($"Got manifest request code for depot {depotId} from app {appId}, manifest {manifestId}, result: {requestCode}");
            }

            return requestCode;
        }

        public async Task RequestCDNAuthToken(uint appid, uint depotid, Server server)
        {
            var cdnKey = (depotid, server.Host);
            var completion = new TaskCompletionSource<SteamContent.CDNAuthToken>();

            if (bAborted || !CDNAuthTokens.TryAdd(cdnKey, completion))
            {
                return;
            }

            DebugLog.WriteLine(nameof(Steam3Session), $"Requesting CDN auth token for {server.Host}");

            var cdnAuth = await steamContent.GetCDNAuthToken(appid, depotid, server.Host);

            Console.WriteLine($"Got CDN auth token for {server.Host} result: {cdnAuth.Result} (expires {cdnAuth.Expiration})");

            if (cdnAuth.Result != EResult.OK)
            {
                return;
            }

            completion.TrySetResult(cdnAuth);
        }

        public async Task CheckAppBetaPassword(uint appid, string password)
        {
            var appPassword = await steamApps.CheckAppBetaPassword(appid, password);

            Console.WriteLine("Retrieved {0} beta keys with result: {1}", appPassword.BetaPasswords.Count, appPassword.Result);

            foreach (var entry in appPassword.BetaPasswords)
            {
                AppBetaPasswords[entry.Key] = entry.Value;
            }
        }

        public async Task<KeyValue> GetPrivateBetaDepotSection(uint appid, string branch)
        {
            if (!AppBetaPasswords.TryGetValue(branch, out var branchPassword)) // Should be filled by CheckAppBetaPassword
            {
                return new KeyValue();
            }

            AppTokens.TryGetValue(appid, out var accessToken); // Should be filled by RequestAppInfo

            var privateBeta = await steamApps.PICSGetPrivateBeta(appid, accessToken, branch, branchPassword);

            Console.WriteLine($"Retrieved private beta depot section for {appid} with result: {privateBeta.Result}");

            return privateBeta.DepotSection;
        }

        public async Task<PublishedFileDetails> GetPublishedFileDetails(uint appId, PublishedFileID pubFile)
        {
            var pubFileRequest = new CPublishedFile_GetDetails_Request { appid = appId };
            pubFileRequest.publishedfileids.Add(pubFile);

            var details = await steamPublishedFile.GetDetails(pubFileRequest);

            if (details.Result == EResult.OK)
            {
                return details.Body.publishedfiledetails.FirstOrDefault();
            }

            throw new Exception($"EResult {(int)details.Result} ({details.Result}) while retrieving file details for pubfile {pubFile}.");
        }


        // Read-only cloud preflight for MacGameDeck. No URLs, authorization headers or save contents are exported.
        public async Task ExportDeckCloudInventory(uint appId, string destination)
        {
            await RequestAppInfo(appId);
            if (ContentDownloader.GetSteam3AppSection(appId, EAppInfoSection.UFS) == null)
            {
                var empty = new { schemaVersion = 1, steamID = steamUser.SteamID.ConvertToUInt64().ToString(), appID = appId,
                    changeNumber = "0", isDelta = false, prefixes = Array.Empty<string>(), files = Array.Empty<object>(), ufs = (object)null };
                System.IO.File.WriteAllText(destination, System.Text.Json.JsonSerializer.Serialize(empty));
                return;
            }
            var cloud = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Cloud>();
            var result = await cloud.GetAppFileChangelist(new CCloud_GetAppFileChangelist_Request { appid = appId, synced_change_number = 0 });
            if (result.Result != EResult.OK)
                throw new DeckCloudException("steam_" + result.Result.ToString());
            if (result.Body.is_only_delta)
                throw new DeckCloudException("partial_inventory");
            object Node(KeyValue node) => new { name = node.Name, value = node.Value, children = node.Children.Select(Node).ToArray() };
            var files = result.Body.files.Select(file => new {
                name = file.file_name, sha1 = Convert.ToHexString(file.sha_file).ToLowerInvariant(),
                size = file.raw_file_size, timestamp = file.time_stamp, state = (int)file.persist_state,
                prefixIndex = file.path_prefix_index
            }).ToArray();
            var value = new {
                schemaVersion = 1, steamID = steamUser.SteamID.ConvertToUInt64().ToString(), appID = appId,
                changeNumber = result.Body.current_change_number.ToString(), isDelta = false,
                prefixes = result.Body.path_prefixes.ToArray(), files,
                ufs = ContentDownloader.GetSteam3AppSection(appId, EAppInfoSection.UFS) is KeyValue ufs ? Node(ufs) : null
            };
            var json = System.Text.Json.JsonSerializer.Serialize(value);
            System.IO.File.WriteAllText(destination, json);
            DeckIntegration.Emit(new { type = "cloud_inventory", appID = appId, count = files.Length });
        }

        // Transfer to staging only; the Swift layer verifies and installs newer saves with backups.
        public async Task DownloadDeckCloud(uint appId, string requestFile, string destination)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                try { await DownloadDeckCloudOnce(appId, requestFile, destination); return; }
                catch (TaskCanceledException) { if (attempt == 2) throw new DeckCloudException("steam_Timeout"); }
                catch (System.Net.Http.HttpRequestException) { if (attempt == 2) throw new DeckCloudException("steam_NoConnection"); }
                await Task.Delay(500 * (attempt + 1));
            }
        }
        private async Task DownloadDeckCloudOnce(uint appId, string requestFile, string destination)
        {
            var requests = System.Text.Json.JsonSerializer.Deserialize<DeckCloudDownload[]>(System.IO.File.ReadAllText(requestFile));
            if (requests == null || requests.Length > 10000) throw new DeckCloudException("invalid_request");
            var cloud = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Cloud>();
            System.IO.Directory.CreateDirectory(destination);
            using var http = HttpClientFactory.CreateHttpClient(false);
            http.Timeout = TimeSpan.FromSeconds(90);
            for (int index = 0; index < requests.Length; index++)
            {
                var file = requests[index];
                if (file.size > 268435456 || file.sha1.Length != 40) throw new DeckCloudException("invalid_request");
                DeckIntegration.Emit(new { type = "cloud_transfer_phase", phase = "metadata", index });
                var response = await cloud.ClientFileDownload(new CCloud_ClientFileDownload_Request { appid = appId, filename = file.name });
                if (response.Result != EResult.OK) throw new DeckCloudException("steam_" + response.Result);
                var body = response.Body;
                if (body.encrypted) throw new DeckCloudException("unsupported_transfer");
                if (body.is_explicit_delete || body.raw_file_size != file.size || body.time_stamp != file.timestamp ||
                    !Convert.ToHexString(body.sha_file).Equals(file.sha1, StringComparison.OrdinalIgnoreCase)) throw new DeckCloudException("cloud_changed");
                if (!Uri.TryCreate((body.use_https ? "https://" : "http://") + body.url_host + body.url_path, UriKind.Absolute, out var url) ||
                    url.Scheme != "https" || !string.IsNullOrEmpty(url.UserInfo)) throw new DeckCloudException("unsupported_transfer");
                using var request = new System.Net.Http.HttpRequestMessage(System.Net.Http.HttpMethod.Get, url);
                foreach (var header in body.request_headers) request.Headers.TryAddWithoutValidation(header.name, header.value);
                DeckIntegration.Emit(new { type = "cloud_transfer_phase", phase = "download", index });
                using var reply = await http.SendAsync(request, System.Net.Http.HttpCompletionOption.ResponseHeadersRead);
                reply.EnsureSuccessStatusCode();
                using var input = await reply.Content.ReadAsStreamAsync();
                using var buffer = new System.IO.MemoryStream();
                var chunk = new byte[65536]; int count;
                while ((count = await input.ReadAsync(chunk)) > 0) { if (buffer.Length + count > 268435456) throw new DeckCloudException("file_too_large"); await buffer.WriteAsync(chunk.AsMemory(0, count)); }
                byte[] bytes = buffer.ToArray();
                if (body.file_size != body.raw_file_size)
                {
                    buffer.Position = 0;
                    using var archive = new System.IO.Compression.ZipArchive(buffer, System.IO.Compression.ZipArchiveMode.Read);
                    if (archive.Entries.Count != 1 || archive.Entries[0].Length != body.raw_file_size) throw new DeckCloudException("unsupported_transfer");
                    using var raw = archive.Entries[0].Open(); using var decoded = new System.IO.MemoryStream();
                    await raw.CopyToAsync(decoded); bytes = decoded.ToArray();
                }
                if ((ulong)bytes.Length != file.size || !Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(bytes)).Equals(file.sha1, StringComparison.OrdinalIgnoreCase))
                    throw new DeckCloudException("hash_mismatch");
                System.IO.File.WriteAllBytes(System.IO.Path.Combine(destination, index.ToString() + ".save"), bytes);
                DeckIntegration.Emit(new { type = "cloud_download", completed = index + 1, total = requests.Length });
            }
        }
        public sealed class DeckCloudDownload
        {
            public string name { get; set; }
            public string sha1 { get; set; }
            public ulong size { get; set; }
            public ulong timestamp { get; set; }
        }

        public sealed class DeckPlayerTotals { public int? minutes; public uint? unlocked; public uint? total; }
        public async Task<Dictionary<uint, DeckPlayerTotals>> DeckPlayerCatalog(IEnumerable<uint> appIds)
        {
            var totals = new Dictionary<uint, DeckPlayerTotals>();
            var player = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Player>();
            var user = steamUser.SteamID.ConvertToUInt64();
            try
            {
                var owned = await player.GetOwnedGames(new CPlayer_GetOwnedGames_Request { steamid = user, include_played_free_games = true, skip_unvetted_apps = false });
                if (owned.Result == EResult.OK)
                    foreach (var game in owned.Body.games) totals[(uint)game.appid] = new DeckPlayerTotals { minutes = game.playtime_forever >= 0 ? game.playtime_forever : null };
                foreach (var batch in appIds.Chunk(100))
                {
                    var query = new CPlayer_GetAchievementsProgress_Request { steamid = user, language = "italian", include_unvetted_apps = true };
                    query.appids.AddRange(batch);
                    var response = await player.GetAchievementsProgress(query);
                    if (response.Result != EResult.OK) continue;
                    foreach (var game in response.Body.achievement_progress)
                    {
                        if (!totals.TryGetValue(game.appid, out var entry)) totals[game.appid] = entry = new DeckPlayerTotals();
                        entry.unlocked = game.unlocked; entry.total = game.total;
                    }
                }
            }
            catch (Exception) { DeckIntegration.Emit(new { type = "player_stats_unavailable" }); }
            return totals;
        }

        public async Task ExportDeckPlayer(uint appId, string destination)
        {
            var player = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Player>();
            var user = steamUser.SteamID.ConvertToUInt64();
            var query = new CPlayer_GetOwnedGames_Request { steamid = user, include_played_free_games = true, skip_unvetted_apps = false };
            query.appids_filter.Add(appId);
            var owned = await player.GetOwnedGames(query);
            if (owned.Result != EResult.OK) throw new DeckCloudException("steam_" + owned.Result);
            var progressQuery = new CPlayer_GetAchievementsProgress_Request { steamid = user, language = "italian", include_unvetted_apps = true };
            progressQuery.appids.Add(appId);
            var progress = await player.GetAchievementsProgress(progressQuery);
            var game = owned.Body.games.FirstOrDefault(g => g.appid == appId);
            var achievements = progress.Result == EResult.OK ? progress.Body.achievement_progress.FirstOrDefault(g => g.appid == appId) : null;
            var value = new { steamID = user.ToString(), appID = appId,
                minutes = game == null ? (int?)null : game.playtime_forever,
                unlocked = achievements == null ? (uint?)null : achievements.unlocked,
                total = achievements == null ? (uint?)null : achievements.total,
                fetchedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds() };
            System.IO.File.WriteAllText(destination, System.Text.Json.JsonSerializer.Serialize(value));
        }

        public async Task<SteamCloud.UGCDetailsCallback> GetUGCDetails(UGCHandle ugcHandle)
        {
            var callback = await steamCloud.RequestUGCDetails(ugcHandle);

            if (callback.Result == EResult.OK)
            {
                return callback;
            }
            else if (callback.Result == EResult.FileNotFound)
            {
                return null;
            }

            throw new Exception($"EResult {(int)callback.Result} ({callback.Result}) while retrieving UGC details for {ugcHandle}.");
        }

        private void ResetConnectionFlags()
        {
            bExpectingDisconnectRemote = false;
            bDidDisconnect = false;
            bIsConnectionRecovery = false;
        }

        void Connect()
        {
            bAborted = false;
            bConnecting = true;
            connectionBackoff = 0;
            authSession = null;

            ResetConnectionFlags();
            this.steamClient.Connect();
        }

        private void Abort(bool sendLogOff = true)
        {
            Disconnect(sendLogOff);
        }

        public void Disconnect(bool sendLogOff = true)
        {
            if (sendLogOff)
            {
                steamUser.LogOff();
            }

            bAborted = true;
            bConnecting = false;
            bIsConnectionRecovery = false;
            abortedToken.Cancel();
            steamClient.Disconnect();

            Ansi.Progress(Ansi.ProgressState.Hidden);

            // flush callbacks until our disconnected event
            while (!bDidDisconnect)
            {
                callbacks.RunWaitAllCallbacks(TimeSpan.FromMilliseconds(100));
            }
        }

        private void Reconnect()
        {
            bIsConnectionRecovery = true;
            steamClient.Disconnect();
        }

        private async void ConnectedCallback(SteamClient.ConnectedCallback connected)
        {
            Console.WriteLine(" Done!");
            bConnecting = false;

            // Update our tracking so that we don't time out, even if we need to reconnect multiple times,
            // e.g. if the authentication phase takes a while and therefore multiple connections.
            connectionBackoff = 0;

            if (!authenticatedUser)
            {
                Console.Write("Logging anonymously into Steam3...");
                steamUser.LogOnAnonymous();
            }
            else
            {
                if (logonDetails.Username != null)
                {
                    Console.WriteLine("Logging '{0}' into Steam3...", logonDetails.Username);
                }

                if (authSession is null)
                {
                    if (logonDetails.Username != null && logonDetails.Password != null && logonDetails.AccessToken is null)
                    {
                        try
                        {
                            _ = AccountSettingsStore.Instance.GuardData.TryGetValue(logonDetails.Username, out var guarddata);
                            authSession = await steamClient.Authentication.BeginAuthSessionViaCredentialsAsync(new AuthSessionDetails
                            {
                                DeviceFriendlyName = "MacGameDeck",
                                Username = logonDetails.Username,
                                Password = logonDetails.Password,
                                IsPersistentSession = ContentDownloader.Config.RememberPassword,
                                GuardData = guarddata,
                                Authenticator = new ConsoleAuthenticator(),
                            });
                        }
                        catch (TaskCanceledException)
                        {
                            return;
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine("Failed to authenticate with Steam: " + ex.Message);
                            Abort(false);
                            return;
                        }
                    }
                    else if (logonDetails.AccessToken is null && ContentDownloader.Config.UseQrCode)
                    {
                        Console.WriteLine("Logging in with QR code...");

                        try
                        {
                            var session = await steamClient.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails
                            {
                                DeviceFriendlyName = "MacGameDeck",
                                IsPersistentSession = ContentDownloader.Config.RememberPassword,
                            });

                            authSession = session;

                            // Steam will periodically refresh the challenge url, so we need a new QR code.
                            session.ChallengeURLChanged = () =>
                            {
                                Console.WriteLine();
                                Console.WriteLine("The QR code has changed:");

                                DisplayQrCode(session.ChallengeURL);
                            };

                            // Draw initial QR code immediately
                            DisplayQrCode(session.ChallengeURL);
                        }
                        catch (TaskCanceledException)
                        {
                            return;
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine("Failed to authenticate with Steam: " + ex.Message);
                            Abort(false);
                            return;
                        }
                    }
                }

                if (authSession != null)
                {
                    try
                    {
                        var result = await authSession.PollingWaitForResultAsync();

                        logonDetails.Username = result.AccountName;
                        logonDetails.Password = null;
                        logonDetails.AccessToken = result.RefreshToken;

                        if (result.NewGuardData != null)
                        {
                            AccountSettingsStore.Instance.GuardData[result.AccountName] = result.NewGuardData;

                            if (ContentDownloader.Config.UseQrCode)
                            {
                                Console.WriteLine($"Success! Next time you can login with -username {result.AccountName} -remember-password instead of -qr.");
                            }
                        }
                        else
                        {
                            AccountSettingsStore.Instance.GuardData.Remove(result.AccountName);
                        }

                        AccountSettingsStore.Instance.LoginTokens[result.AccountName] = result.RefreshToken;
                        AccountSettingsStore.Save();
                    }
                    catch (TaskCanceledException)
                    {
                        return;
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine("Failed to authenticate with Steam: " + ex.Message);
                        Abort(false);
                        return;
                    }

                    authSession = null;
                }

                steamUser.LogOn(logonDetails);
            }
        }

        private void DisconnectedCallback(SteamClient.DisconnectedCallback disconnected)
        {
            bDidDisconnect = true;

            DebugLog.WriteLine(nameof(Steam3Session), $"Disconnected: bIsConnectionRecovery = {bIsConnectionRecovery}, UserInitiated = {disconnected.UserInitiated}, bExpectingDisconnectRemote = {bExpectingDisconnectRemote}");

            // When recovering the connection, we want to reconnect even if the remote disconnects us
            if (!bIsConnectionRecovery && (disconnected.UserInitiated || bExpectingDisconnectRemote))
            {
                Console.WriteLine("Disconnected from Steam");

                // Any operations outstanding need to be aborted
                bAborted = true;
            }
            else if (connectionBackoff >= 10)
            {
                Console.WriteLine("Could not connect to Steam after 10 tries");
                Abort(false);
            }
            else if (!bAborted)
            {
                connectionBackoff += 1;

                if (bConnecting)
                {
                    Console.WriteLine($"Connection to Steam failed. Trying again (#{connectionBackoff})...");
                }
                else
                {
                    Console.WriteLine("Lost connection to Steam. Reconnecting");
                }

                Thread.Sleep(1000 * connectionBackoff);

                // Any connection related flags need to be reset here to match the state after Connect
                ResetConnectionFlags();
                steamClient.Connect();
            }
        }

        private void LogOnCallback(SteamUser.LoggedOnCallback loggedOn)
        {
            var isSteamGuard = loggedOn.Result == EResult.AccountLogonDenied;
            var is2FA = loggedOn.Result == EResult.AccountLoginDeniedNeedTwoFactor;
            var isAccessToken = ContentDownloader.Config.RememberPassword && logonDetails.AccessToken != null &&
                loggedOn.Result is EResult.InvalidPassword
                or EResult.InvalidSignature
                or EResult.AccessDenied
                or EResult.Expired
                or EResult.Revoked;

            if (isSteamGuard || is2FA || isAccessToken)
            {
                bExpectingDisconnectRemote = true;
                Abort(false);

                if (!isAccessToken)
                {
                    Console.WriteLine("This account is protected by Steam Guard.");
                }

                if (is2FA)
                {
                    do
                    {
                        Console.Write("Please enter your 2 factor auth code from your authenticator app: ");
                        logonDetails.TwoFactorCode = Console.ReadLine();
                    } while (string.Empty == logonDetails.TwoFactorCode);
                }
                else if (isAccessToken)
                {
                    AccountSettingsStore.Instance.LoginTokens.Remove(logonDetails.Username);
                    AccountSettingsStore.Save();

                    // TODO: Handle gracefully by falling back to password prompt?
                    Console.WriteLine($"Access token was rejected ({loggedOn.Result}).");
                    Abort(false);
                    return;
                }
                else
                {
                    do
                    {
                        Console.Write("Please enter the authentication code sent to your email address: ");
                        logonDetails.AuthCode = Console.ReadLine();
                    } while (string.Empty == logonDetails.AuthCode);
                }

                Console.Write("Retrying Steam3 connection...");
                Connect();

                return;
            }

            if (loggedOn.Result == EResult.TryAnotherCM)
            {
                Console.Write("Retrying Steam3 connection (TryAnotherCM)...");

                Reconnect();

                return;
            }

            if (loggedOn.Result == EResult.ServiceUnavailable)
            {
                Console.WriteLine("Unable to login to Steam3: {0}", loggedOn.Result);
                Abort(false);

                return;
            }

            if (loggedOn.Result != EResult.OK)
            {
                Console.WriteLine("Unable to login to Steam3: {0}", loggedOn.Result);
                Abort();

                return;
            }

            if (!DeckIntegration.Account(steamUser.SteamID.ConvertToUInt64().ToString(), logonDetails.Username))
            {
                Abort(false);
                return;
            }
            Console.WriteLine(" Done!");

            this.seq++;
            IsLoggedOn = true;

            if (ContentDownloader.Config.CellID == 0)
            {
                Console.WriteLine("Using Steam3 suggested CellID: " + loggedOn.CellID);
                ContentDownloader.Config.CellID = (int)loggedOn.CellID;
            }
        }

        private void LicenseListCallback(SteamApps.LicenseListCallback licenseList)
        {
            if (licenseList.Result != EResult.OK)
            {
                Console.WriteLine("Unable to get license list: {0} ", licenseList.Result);
                Abort();

                return;
            }

            Console.WriteLine("Got {0} licenses for account!", licenseList.LicenseList.Count);
            Licenses = licenseList.LicenseList;

            foreach (var license in licenseList.LicenseList)
            {
                if (license.AccessToken > 0)
                {
                    PackageTokens.TryAdd(license.PackageID, license.AccessToken);
                }
            }
        }

        private static void DisplayQrCode(string challengeUrl)
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MACGAMEDECK_PROTOCOL")))
            {
                DeckIntegration.Emit(new { type = "qr", url = challengeUrl });
                return;
            }
            // Encode the link as a QR code
            using var qrGenerator = new QRCodeGenerator();
            var qrCodeData = qrGenerator.CreateQrCode(challengeUrl, QRCodeGenerator.ECCLevel.L);
            using var qrCode = new AsciiQRCode(qrCodeData);
            var qrCodeAsAsciiArt = qrCode.GetLineByLineGraphic(1, drawQuietZones: true);

            Console.WriteLine("Use the Steam Mobile App to sign in with this QR code:");

            foreach (var line in qrCodeAsAsciiArt)
            {
                Console.WriteLine(line);
            }
        }
    }
}
