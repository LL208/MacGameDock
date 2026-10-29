// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using SteamKit2;
using SteamKit2.Internal;

namespace DepotDownloader
{
    partial class Steam3Session
    {
        public sealed class DeckAchievement
        {
            public string name { get; set; }
            public string title { get; set; }
            public string description { get; set; }
            public string icon { get; set; }
            public string iconGray { get; set; }
            public bool hidden { get; set; }
            public bool unlocked { get; set; }
            public uint unlockTime { get; set; }
            public uint statID { get; set; }
            public int bit { get; set; }
        }
        public sealed class DeckSnapshot
        {
            public string steamID { get; set; }
            public uint appID { get; set; }
            public List<DeckAchievement> achievements { get; set; }
            public object[] stats { get; set; }
        }
        private DeckStatsHandler StatsHandler()
        {
            var handler = steamClient.GetHandler<DeckStatsHandler>();
            if (handler == null) { handler = new DeckStatsHandler(); steamClient.AddHandler(handler); }
            return handler;
        }
        private static KeyValue FindStats(KeyValue node, int depth = 0)
        {
            if (node.Name == "stats") return node;
            if (depth > 4) return null;
            foreach (var child in node.Children) { var found = FindStats(child, depth + 1); if (found != null) return found; }
            return null;
        }
        private static readonly System.Threading.AsyncLocal<string> deckLanguage = new();
        private static string Localized(KeyValue node)
        {
            var language = (deckLanguage.Value ?? Environment.GetEnvironmentVariable("MACGAMEDECK_LANGUAGE")) == "italian" ? "italian" : "english";
            return node[language].AsString() ?? node["english"].AsString() ?? node.Value ?? "";
        }
        internal static List<DeckAchievement> ParseAchievements(uint appId, CMsgClientGetUserStatsResponse response)
        {
            var root = new KeyValue();
            using var stream = new MemoryStream(response.schema);
            if (response.schema.Length > 16000000 || !root.TryReadAsBinary(stream)) throw new DeckCloudException("invalid_schema");
            var stats = FindStats(root);
            var achievements = new List<DeckAchievement>();
            if (stats == null) return achievements;
            foreach (var stat in stats.Children)
            {
                if (!uint.TryParse(stat.Name, out var statId) || !(stat["type"].AsInteger() == 4 || stat["type"].AsString()?.ToUpperInvariant() is "ACHIEVEMENTS" or "BITS")) continue;
                var block = response.achievement_blocks.FirstOrDefault(b => b.achievement_id == statId);
                foreach (var flag in stat["bits"].Children)
                {
                    if (!int.TryParse(flag.Name, out var bit) || bit < 0 || bit > 31 || string.IsNullOrEmpty(flag["name"].AsString())) continue;
                    var display = flag["display"];
                    var time = block != null && bit < block.unlock_time.Count ? block.unlock_time[bit] : 0;
                    string Icon(string value) => string.IsNullOrEmpty(value) ? null : "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/" + appId + "/" + value;
                    achievements.Add(new DeckAchievement { name = flag["name"].AsString(), title = Localized(display["name"]), description = Localized(display["desc"]),
                        icon = Icon(display["icon"].AsString()), iconGray = Icon(display["icon_gray"].AsString()), hidden = display["hidden"].AsInteger() != 0,
                        unlocked = time != 0, unlockTime = time, statID = statId, bit = bit });
                }
            }
            return achievements;
        }
        public async Task<DeckSnapshot> ReadDeckAchievements(uint appId)
        {
            var result = (await StatsHandler().Read(appId, steamUser.SteamID.ConvertToUInt64())).Body;
            if ((EResult)result.eresult != EResult.OK || result.game_id != appId) throw new DeckCloudException("steam_" + (EResult)result.eresult);
            var root = new KeyValue(); using var stream = new MemoryStream(result.schema); root.TryReadAsBinary(stream);
            var stats = FindStats(root);
            var definitions = new List<object>();
            foreach (var stat in stats?.Children ?? [])
            {
                var type = stat["type"].AsString()?.ToUpperInvariant();
                var isInteger = stat["type"].AsInteger() == 1 || type == "INT";
                var isFloat = stat["type"].AsInteger() == 2 || type == "FLOAT";
                if (!isInteger && !isFloat) continue;
                var name = stat["name"].AsString(); if (string.IsNullOrEmpty(name)) continue;
                var value = uint.TryParse(stat.Name, out var id) ? result.stats.FirstOrDefault(s => s.stat_id == id) : null;
                var initial = value == null ? stat["Default"].Value ?? "0" : isInteger ? unchecked((int)value.stat_value).ToString(System.Globalization.CultureInfo.InvariantCulture) : BitConverter.Int32BitsToSingle(unchecked((int)value.stat_value)).ToString(System.Globalization.CultureInfo.InvariantCulture);
                definitions.Add(new { name, type = isInteger ? "int" : "float", defaultValue = initial });
            }
            return new DeckSnapshot { steamID = steamUser.SteamID.ConvertToUInt64().ToString(), appID = appId, achievements = ParseAchievements(appId, result), stats = definitions.ToArray() };
        }
        public async Task ExportDeckAchievements(uint appId, string destination)
        {
            File.WriteAllText(destination, JsonSerializer.Serialize(await ReadDeckAchievements(appId)));
        }
        internal static CMsgClientStoreUserStats2 BuildStoreRequest(uint appId, ulong owner, CMsgClientGetUserStatsResponse current, string[] names)
        {
            var definitions = ParseAchievements(appId, current);
            var requested = definitions.Where(a => names.Contains(a.name)).ToArray();
            if (requested.Length != names.Distinct().Count()) throw new DeckCloudException("invalid_achievement");
            var blocks = new Dictionary<uint, uint>();
            foreach (var block in current.achievement_blocks)
            {
                uint mask = 0; for (var bit = 0; bit < Math.Min(32, block.unlock_time.Count); bit++) if (block.unlock_time[bit] > 0) mask |= 1u << bit;
                blocks[block.achievement_id] = mask;
            }
            var body = new CMsgClientStoreUserStats2 { game_id = appId, settor_steam_id = owner, settee_steam_id = owner, crc_stats = current.crc_stats };
            foreach (var group in requested.GroupBy(a => a.statID))
            {
                var mask = blocks.GetValueOrDefault(group.Key);
                foreach (var achievement in group) mask |= 1u << achievement.bit;
                body.stats.Add(new CMsgClientStoreUserStats2.Stats { stat_id = group.Key, stat_value = mask });
            }
            return body;
        }
        public async Task StoreDeckAchievements(uint appId, string[] names)
        {
            if (names.Length == 0 || names.Length > 10000) throw new DeckCloudException("invalid_request");
            var handler = StatsHandler(); var owner = steamUser.SteamID.ConvertToUInt64();
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var current = (await handler.Read(appId, owner)).Body;
                if ((EResult)current.eresult != EResult.OK || current.game_id != appId) throw new DeckCloudException("steam_" + (EResult)current.eresult);
                var body = BuildStoreRequest(appId, owner, current, names);
                var saved = (await handler.Write(body)).Body;
                if ((EResult)saved.eresult != EResult.OK) throw new DeckCloudException("steam_" + (EResult)saved.eresult);
                if (saved.stats_out_of_date && attempt == 0) continue;
                if (saved.stats_out_of_date || saved.stats_failed_validation.Count > 0) throw new DeckCloudException("stats_rejected");
                var verified = await ReadDeckAchievements(appId);
                if (names.Any(name => !verified.achievements.Any(v => v.name == name && v.unlocked))) throw new DeckCloudException("stats_unconfirmed");
                return;
            }
        }
        public async Task ExportDeckWorkshop(uint appId, string destination, string search, uint page)
        {
            var query = new CPublishedFile_QueryFiles_Request { appid = appId, query_type = 0, page = Math.Clamp(page, 1, 1000), numperpage = 24, search_text = search ?? "", filetype = 0,
                return_details = true, return_short_description = true, return_previews = true, strip_description_bbcode = true };
            var response = await steamPublishedFile.QueryFiles(query);
            if (response.Result != EResult.OK) throw new DeckCloudException("steam_" + response.Result);
            var items = response.Body.publishedfiledetails.Where(f => f.consumer_appid == appId && f.file_type == 0 && f.result == 1).Select(f => new {
                id = f.publishedfileid.ToString(), title = f.title, description = f.short_description, preview = f.preview_url, subscriptions = f.subscriptions
            }).ToArray();
            File.WriteAllText(destination, JsonSerializer.Serialize(new { appID = appId, steamID = steamUser.SteamID.ConvertToUInt64().ToString(), total = response.Body.total, page, items }));
        }
        public async Task RunDeckService(string directory, int parentPid)
        {
            Directory.CreateDirectory(directory);
            var friends = steamClient.GetHandler<SteamFriends>();
            friends.RequestFriendInfo(steamUser.SteamID, EClientPersonaStateFlag.PlayerName);
            byte[] profileAvatar = null; string profileName = null;
            try {
                var player = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Player>();
                var query = new CPlayer_GetPlayerLinkDetails_Request(); query.steamids.Add(steamUser.SteamID.ConvertToUInt64());
                var response = await player.GetPlayerLinkDetails(query);
                if (response.Result == EResult.OK) {
                    var data = response.Body.accounts.FirstOrDefault(a => a.public_data?.steamid == steamUser.SteamID.ConvertToUInt64())?.public_data;
                    profileAvatar = data?.sha_digest_avatar; profileName = data?.persona_name;
                }
            } catch (Exception) { }
            var blocked = false;
            using var subscription = callbacks.Subscribe<SteamUser.PlayingSessionStateCallback>(state => { blocked = state.PlayingBlocked; });
            var readCommands = new HashSet<string>();
            var watchedGames = new Dictionary<uint, uint>(); long playingRevision = 0;
            bool Alive(int pid) { try { return !System.Diagnostics.Process.GetProcessById(pid).HasExited; } catch { return false; } }
            void NotifyPlaying() {
                var message = new ClientMsgProtobuf<CMsgClientGamesPlayed>(EMsg.ClientGamesPlayed);
                foreach (var game in watchedGames) message.Body.games_played.Add(new CMsgClientGamesPlayed.GamePlayed { game_id = game.Key, process_id = game.Value, owner_id = steamUser.SteamID.AccountID });
                steamClient.Send(message);
            }
            void Write(string id, object value)
            {
                var file = Path.Combine(directory, "result-" + id + ".json"); var temp = file + ".tmp";
                File.WriteAllText(temp, JsonSerializer.Serialize(value)); File.Move(temp, file, true);
            }
            while (IsLoggedOn && !File.Exists(Path.Combine(directory, "stop")) && (parentPid == 0 || Alive(parentPid)))
            {
                var exited = watchedGames.Where(g => !Alive((int)g.Value)).Select(g => g.Key).ToArray();
                foreach (var id in exited) watchedGames.Remove(id);
                if (exited.Length > 0) NotifyPlaying();
                var avatar = profileAvatar ?? friends.GetFriendAvatar(steamUser.SteamID);
                Write("profile", new { steamID = steamUser.SteamID.ConvertToUInt64().ToString(), name = profileName ?? friends.GetPersonaName(), avatar = avatar == null ? null : "https://avatars.steamstatic.com/" + Convert.ToHexString(avatar).ToLowerInvariant() + "_full.jpg", state = (int)friends.GetPersonaState(), blocked });
                foreach (var file in Directory.GetFiles(directory, "command-*.json"))
                {
                    var id = Path.GetFileName(file).Replace("command-", "").Replace(".json", "");
                    if (!Guid.TryParse(id, out _) || readCommands.Contains(id)) continue;
                    readCommands.Add(id);
                    try
                    {
                        using var document = JsonDocument.Parse(File.ReadAllText(file)); var command = document.RootElement;
                        if (command.GetProperty("steamID").GetString() != steamUser.SteamID.ConvertToUInt64().ToString()) throw new DeckCloudException("wrong_account");
                        var kind = command.GetProperty("kind").GetString(); var appId = command.TryGetProperty("appID", out var app) ? app.GetUInt32() : 0;
                        deckLanguage.Value = command.TryGetProperty("language", out var language) && language.GetString() == "italian" ? "italian" : "english";
                        switch (kind)
                        {
                            case "presence":
                                var state = command.GetProperty("state").GetInt32(); if (state < 0 || state > 7) throw new DeckCloudException("invalid_request");
                                friends.SetPersonaState((EPersonaState)state); Write(id, new { ok = true }); break;
                            case "achievements": Write(id, new { ok = true, snapshot = await ReadDeckAchievements(appId) }); break;
                            case "unlock":
                                var names = command.GetProperty("names").EnumerateArray().Select(n => n.GetString()).ToArray();
                                await StoreDeckAchievements(appId, names); Write(id, new { ok = true, snapshot = await ReadDeckAchievements(appId) }); break;
                            case "playing":
                                var revision = command.GetProperty("revision").GetInt64();
                                if (revision <= playingRevision) { Write(id, new { ok = true }); break; }
                                playingRevision = revision;
                                var games = command.GetProperty("games").EnumerateArray().ToArray();
                                if (games.Length > 0 && blocked) throw new DeckCloudException("playing_elsewhere");
                                watchedGames.Clear();
                                foreach (var game in games) {
                                    var processId = game.GetProperty("processID").GetUInt32();
                                    if (Alive((int)processId)) watchedGames[game.GetProperty("appID").GetUInt32()] = processId;
                                }
                                NotifyPlaying(); Write(id, new { ok = true }); break;
                            default: throw new DeckCloudException("invalid_request");
                        }
                    }
                    catch (Exception error) { Write(id, new { ok = false, error = error is DeckCloudException known ? known.Code : "service_error" }); }
                    finally { try { File.Delete(file); } catch { } }
                }
                await Task.Delay(300);
            }
        }
    }
}
