// This file is subject to the terms and conditions defined
// in file 'LICENSE', which is part of this source code package.

using System.Text;
using SteamKit2;

namespace DepotDownloader
{
    // An app installation identity avoids native disk probes returning null in macOS.
    // It is stable between operations and never derived from a password or refresh token.
    internal sealed class DeckMachineInfoProvider(string identity) : IMachineInfoProvider
    {
        private byte[] Value(string field) => Encoding.UTF8.GetBytes("MacGameDeck/" + identity + "/" + field);
        public byte[] GetMachineGuid() => Value("installation");
        public byte[] GetMacAddress() => Value("network");
        public byte[] GetDiskId() => Value("storage");
    }
}
