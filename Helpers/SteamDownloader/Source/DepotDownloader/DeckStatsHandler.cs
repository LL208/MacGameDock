// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

using SteamKit2;
using SteamKit2.Internal;

namespace DepotDownloader
{
    internal sealed class DeckStatsHandler : ClientMsgHandler
    {
        public sealed class ReadCallback : CallbackMsg { public CMsgClientGetUserStatsResponse Body { get; init; } }
        public sealed class WriteCallback : CallbackMsg { public CMsgClientStoreUserStatsResponse Body { get; init; } }
        public override void HandleMsg(IPacketMsg packet)
        {
            if (packet.MsgType == EMsg.ClientGetUserStatsResponse)
            {
                var message = new ClientMsgProtobuf<CMsgClientGetUserStatsResponse>(packet);
                Client.PostCallback(new ReadCallback { JobID = message.TargetJobID, Body = message.Body });
            }
            else if (packet.MsgType == EMsg.ClientStoreUserStatsResponse)
            {
                var message = new ClientMsgProtobuf<CMsgClientStoreUserStatsResponse>(packet);
                Client.PostCallback(new WriteCallback { JobID = message.TargetJobID, Body = message.Body });
            }
        }
        public AsyncJob<ReadCallback> Read(uint appId, ulong owner)
        {
            var message = new ClientMsgProtobuf<CMsgClientGetUserStats>(EMsg.ClientGetUserStats) { SourceJobID = Client.GetNextJobID() };
            message.Body.game_id = appId; message.Body.steam_id_for_user = owner;
            var job = new AsyncJob<ReadCallback>(Client, message.SourceJobID) { Timeout = System.TimeSpan.FromSeconds(30) };
            Client.Send(message);
            return job;
        }
        public AsyncJob<WriteCallback> Write(CMsgClientStoreUserStats2 body)
        {
            var message = new ClientMsgProtobuf<CMsgClientStoreUserStats2>(EMsg.ClientStoreUserStats2) { SourceJobID = Client.GetNextJobID() };
            message.Body.game_id = body.game_id; message.Body.settor_steam_id = body.settor_steam_id; message.Body.settee_steam_id = body.settee_steam_id; message.Body.crc_stats = body.crc_stats;
            message.Body.stats.AddRange(body.stats);
            var job = new AsyncJob<WriteCallback>(Client, message.SourceJobID) { Timeout = System.TimeSpan.FromSeconds(30) };
            Client.Send(message); return job;
        }
    }
}
