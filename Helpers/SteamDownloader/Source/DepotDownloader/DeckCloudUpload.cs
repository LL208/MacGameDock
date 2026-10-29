// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.
using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;
using SteamKit2;
using SteamKit2.Internal;

namespace DepotDownloader {
    partial class Steam3Session {
        internal sealed class DeckCloudUploadRequest {
            public string steamID { get; set; }
            public uint appID { get; set; }
            public string changeNumber { get; set; }
            public DeckCloudUploadFile[] files { get; set; }
        }
        internal sealed class DeckCloudUploadFile {
            public string name { get; set; }
            public string sha1 { get; set; }
            public uint size { get; set; }
            public ulong timestamp { get; set; }
            public string source { get; set; }
        }
        internal static bool SafeCloudName(string name) => !string.IsNullOrEmpty(name) && !name.StartsWith('/') && !name.Contains('\\') && !name.Contains(':') && !name.Contains('\0') && !name.Split('/').Any(p => p == "." || p == "..");
        internal static void ValidateUpload(DeckCloudUploadRequest request, uint appId, string owner) {
            if (request == null || request.appID != appId || request.steamID != owner || !ulong.TryParse(request.changeNumber, out _) || request.files == null || request.files.Length == 0 || request.files.Length > 10000)
                throw new DeckCloudException("invalid_request");
            if (request.files.Select(f => f.name).Distinct().Count() != request.files.Length) throw new DeckCloudException("invalid_request");
            foreach (var file in request.files) {
                if (!SafeCloudName(file.name) || file.size > 268435456 || file.sha1 == null || file.sha1.Length != 40 || !file.sha1.All(Uri.IsHexDigit) || file.timestamp == 0 || file.timestamp > (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300 || file.source == null || file.source.Contains('/') || file.source.Contains('\\') || file.source is "." or "..")
                    throw new DeckCloudException("invalid_request");
            }
        }
        public async Task UploadDeckCloud(uint appId, string requestFile) {
            var request = JsonSerializer.Deserialize<DeckCloudUploadRequest>(File.ReadAllText(requestFile));
            ValidateUpload(request, appId, steamUser.SteamID.ConvertToUInt64().ToString());
            var directory = Path.GetDirectoryName(Path.GetFullPath(requestFile));
            foreach (var file in request.files) {
                var path = Path.Combine(directory, file.source);
                var info = new FileInfo(path);
                if (!info.Exists || info.LinkTarget != null || info.Length != file.size || !Convert.ToHexString(SHA1.HashData(File.ReadAllBytes(path))).Equals(file.sha1, StringComparison.OrdinalIgnoreCase)) throw new DeckCloudException("hash_mismatch");
            }
            var cloud = steamClient.GetHandler<SteamUnifiedMessages>().CreateService<Cloud>();
            var current = await cloud.GetAppFileChangelist(new CCloud_GetAppFileChangelist_Request { appid = appId, synced_change_number = 0 });
            if (current.Result != EResult.OK) throw new DeckCloudException("steam_" + current.Result);
            if (current.Body.is_only_delta || current.Body.current_change_number.ToString() != request.changeNumber) throw new DeckCloudException("cloud_changed");
            var machine = Environment.GetEnvironmentVariable("MACGAMEDECK_MACHINE_ID");
            var clientId = Guid.TryParse(machine, out var machineGuid) ? BitConverter.ToUInt64(machineGuid.ToByteArray(), 0) : 0UL;
            var begin = new CCloud_BeginAppUploadBatch_Request { appid = appId, machine_name = "MacGameDeck", client_id = clientId };
            begin.files_to_upload.AddRange(request.files.Select(f => f.name));
            DeckIntegration.Emit(new { type = "cloud_upload_phase", phase = "batch" });
            var batch = await cloud.BeginAppUploadBatch(begin);
            if (batch.Result != EResult.OK) throw new DeckCloudException("steam_" + batch.Result);
            var success = false;
            try {
                // A batch may reserve a new change number. Compare file contents, not that reservation.
                var locked = await cloud.GetAppFileChangelist(new CCloud_GetAppFileChangelist_Request { appid = appId, synced_change_number = 0 });
                if (locked.Result != EResult.OK || locked.Body.is_only_delta) throw new DeckCloudException("cloud_changed");
                string[] Snapshot(CCloud_GetAppFileChangelist_Response value) => value.files.Select(f => {
                    var prefix = value.path_prefixes.Count == 0 ? "" : value.path_prefixes[(int)f.path_prefix_index];
                    return prefix + "/" + f.file_name + ":" + Convert.ToHexString(f.sha_file) + ":" + f.persist_state + ":" + f.time_stamp;
                }).OrderBy(v => v, StringComparer.Ordinal).ToArray();
                if (!Snapshot(current.Body).SequenceEqual(Snapshot(locked.Body))) throw new DeckCloudException("cloud_changed");
                using var http = HttpClientFactory.CreateHttpClient(false); http.Timeout = TimeSpan.FromSeconds(90);
                foreach (var file in request.files) {
                    var bytes = File.ReadAllBytes(Path.Combine(directory, file.source));
                    if (bytes.Length != file.size || !Convert.ToHexString(SHA1.HashData(bytes)).Equals(file.sha1, StringComparison.OrdinalIgnoreCase)) throw new DeckCloudException("hash_mismatch");
                    var sha = Convert.FromHexString(file.sha1);
                    DeckIntegration.Emit(new { type = "cloud_upload_phase", phase = "file_begin" });
                    var upload = await cloud.ClientBeginFileUpload(new CCloud_ClientBeginFileUpload_Request {
                        appid = appId, filename = file.name, file_size = file.size, raw_file_size = file.size, file_sha = sha,
                        time_stamp = file.timestamp, platforms_to_sync = uint.MaxValue, can_encrypt = false, upload_batch_id = batch.Body.batch_id
                    });
                    if (upload.Result == EResult.DuplicateRequest) {
                        // Steam deduplicates an already stored payload. Accept only an exact remote hash/size match.
                        var stored = current.Body.files.FirstOrDefault(f => {
                            var prefix = current.Body.path_prefixes.Count == 0 ? "" : current.Body.path_prefixes[(int)f.path_prefix_index];
                            var name = prefix + (prefix.Length == 0 || prefix.EndsWith('/') || prefix.EndsWith('%') ? "" : "/") + f.file_name;
                            return name == file.name && (int)f.persist_state == 0 && f.raw_file_size == file.size && Convert.ToHexString(f.sha_file).Equals(file.sha1, StringComparison.OrdinalIgnoreCase);
                        });
                        if (stored == null) throw new DeckCloudException("cloud_changed");
                        DeckIntegration.Emit(new { type = "cloud_upload_phase", phase = "already_stored" });
                        continue;
                    }
                    if (upload.Result != EResult.OK) throw new DeckCloudException("steam_" + upload.Result);
                    if (upload.Body.encrypt_file) throw new DeckCloudException("unsupported_transfer");
                    var transferred = false;
                    try {
                        foreach (var block in upload.Body.block_requests) {
                            if (!block.use_https || !Uri.TryCreate("https://" + block.url_host + block.url_path, UriKind.Absolute, out var url) || url.Scheme != "https" || !string.IsNullOrEmpty(url.UserInfo) || block.block_offset > (ulong)bytes.Length || block.block_length > (ulong)bytes.Length - block.block_offset) throw new DeckCloudException("unsupported_transfer");
                            // Valve EHTTPMethod: POST=3, PUT=4. Other methods cannot upload a save.
                            var method = block.http_method switch { 3 => HttpMethod.Post, 4 => HttpMethod.Put, _ => throw new DeckCloudException("unsupported_transfer") };
                            using var message = new HttpRequestMessage(method, url);
                            message.Content = block.explicit_body_data.Length > 0 ? new ByteArrayContent(block.explicit_body_data) : new ByteArrayContent(bytes, checked((int)block.block_offset), checked((int)block.block_length));
                            foreach (var header in block.request_headers) if (!message.Headers.TryAddWithoutValidation(header.name, header.value)) message.Content.Headers.TryAddWithoutValidation(header.name, header.value);
                            using var reply = await http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead); reply.EnsureSuccessStatusCode();
                        }
                        transferred = true;
                    } finally {
                        DeckIntegration.Emit(new { type = "cloud_upload_phase", phase = "file_commit" });
                        var commit = await cloud.ClientCommitFileUpload(new CCloud_ClientCommitFileUpload_Request { appid = appId, filename = file.name, file_sha = sha, transfer_succeeded = transferred });
                        if (transferred && (commit.Result != EResult.OK || !commit.Body.file_committed)) throw new DeckCloudException("upload_unconfirmed");
                    }
                    DeckIntegration.Emit(new { type = "cloud_upload", appID = appId });
                }
                success = true;
            } finally {
                DeckIntegration.Emit(new { type = "cloud_upload_phase", phase = "batch_complete" });
                var complete = await cloud.CompleteAppUploadBatchBlocking(new CCloud_CompleteAppUploadBatch_Request { appid = appId, batch_id = batch.Body.batch_id, batch_eresult = (uint)(success ? EResult.OK : EResult.Fail) });
                if (success && complete.Result != EResult.OK) throw new DeckCloudException("upload_unconfirmed");
            }
            DeckIntegration.Emit(new { type = "cloud_upload_complete", appID = appId, count = request.files.Length });
        }
    }
}
