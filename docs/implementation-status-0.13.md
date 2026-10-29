# Native game details — 0.13.0

Desktop and Big Picture provide short/full store descriptions, genres, developer, current Steam player count and declared single-player, online, local co-op and shared/split-screen modes. At this version descriptions request Italian when available. A missing category means undeclared, not proven incompatibility. The API does not supply a local-player maximum; the UI leaves it unspecified.

Achievements automatically load schema and progress, immediately reuse the account/game cache and receive monitor updates. Metadata, player counts and achievements load independently. Late responses are discarded after changing games/accounts. Reading details does not prepare the Steam API bridge or alter game files.

SteamSocial is preferred when connected. Downloader fallback waits for existing operations and uses its own UUID. Closing the page or launching a game cancels only the page-owned read, never unrelated downloads.

## Verification

Tests cover description/mode parsing, zero players vs. unavailable data, achievement loading when metadata is offline, account-separated caches, offline reuse and stale-response rejection. Services are simulated: these tests did not produce a newly earned Steam achievement. Live counts and personal schemas require Steam availability and the user's session.
