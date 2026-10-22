# Steam protocol regression runner

Run `dotnet run --project Helpers/SteamDownloader/Tests/SteamProtocolRegression.csproj` after restoring the pinned helper dependencies. No network connection to Steam, credentials or account mutation is required. The runner covers binary schema text/numeric achievement types, existing-bit preservation, no reset, correct owner/CRC, and rejection of unknown names. Swift runtime/queue tests are in Tests/MacGameDockTests.
