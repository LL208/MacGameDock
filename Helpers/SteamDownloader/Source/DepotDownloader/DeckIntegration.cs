// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using SteamKit2;

namespace DepotDownloader
{
    // MacGameDeck integration changes, 2026-10-12.
    internal static class DeckIntegration
    {
        public static void Emit(object value) => Console.WriteLine("MACGAMEDECK_EVENT:" + JsonSerializer.Serialize(value));

        private static long lastProgress;
        public static void Progress(ulong done, ulong total)
        {
            var now = Environment.TickCount64;
            var previous = System.Threading.Interlocked.Read(ref lastProgress);
            if (now - previous < 500 || System.Threading.Interlocked.CompareExchange(ref lastProgress, now, previous) != previous) return;
            Emit(new { type = "download_progress", done, total });
        }

        public static bool Account(string steamID, string username)
        {
            var expected = Environment.GetEnvironmentVariable("MACGAMEDECK_EXPECTED_STEAMID");
            if (!string.IsNullOrEmpty(expected) && expected != steamID)
            {
                Emit(new { type = "account_mismatch" });
                return false;
            }
            Emit(new { type = "account", steamID, username });
            return true;
        }

        public static void Metadata(uint appID, KeyValue common, KeyValue config, string installDirectory)
        {
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MACGAMEDECK_PROTOCOL"))) return;
            var launches = config?["launch"].Children.Select(entry => new {
                executable = entry["executable"].AsString(), arguments = entry["arguments"].AsString(),
                workingDirectory = entry["workingdir"].AsString(), description = entry["description"].AsString(),
                oslist = entry["config"]["oslist"].AsString(), osarch = entry["config"]["osarch"].AsString()
            }).ToArray();
            var value = new { appID, title = common?["name"].AsString(), launches };
            var target = Path.Combine(installDirectory, ".MacGameDeck");
            Directory.CreateDirectory(target);
            File.WriteAllText(Path.Combine(target, "metadata.json"), JsonSerializer.Serialize(value));
            Emit(new { type = "download_complete", appID });
        }
    }
}
