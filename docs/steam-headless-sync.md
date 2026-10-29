# Steam integration without the graphical client

MacGameDeck uses an internal SteamKit2 service for authenticated downloads, cloud operations and activity while launching games directly. Reintroducing the Steam.app/steam.exe launch path from 0.6.0 would restore the installation regressions that prompted its removal.

The original test title is Cruelty Squad (App ID 1388770), which advertises Steam Cloud and achievements. This document separates architectural requirements from historical implementation milestones. See the [main README](../README.md) for current scope.

## Three different responsibilities

| Feature | During play | After exit | Important constraint |
| --- | --- | --- | --- |
| Auto-Cloud saves | The game writes local files | Compare/upload changes; restore before next launch | UFS metadata, platform root overrides, conflicts and save-format compatibility |
| Steam playtime | Authenticated GamesPlayed for the real monitored process | Signal exit and read server totals | Do not add offline time retroactively or displace another device's active session |
| Achievements | A compatible Steamworks bridge records real SetAchievement/StoreStats events | Submit validated events with an offline journal | ABI/interface versions vary; elapsed time or arbitrary save contents do not prove an unlock |

SteamKit2 supplies transport to Steam services, not the Steamworks ABI expected by a Windows game. A Wine-compatible bridge is required for supported titles. GameNative demonstrates the combination of a compatible component such as GSE/Goldberg and an authenticated synchronization service; its Android libraries are not drop-in macOS components.

Preserve original game libraries and direct launching. Never infer achievements, unlock them in bulk or declare synchronization successful merely because a process exited.

## Required flow

1. Reuse the saved session, coordinate operation ownership and use distinct LoginIDs where concurrent helpers are needed. Respect PlayedElsewhere/PlayingBlocked without taking over another device.
2. Bind cloud preflight to SteamID/AppID and map declared UFS paths into authorized container locations.
3. Compare content hashes, timestamps and baseline state. Preserve versioned backups before restoration. Conflicting content needs explicit handling; deletions must not propagate automatically.
4. Download into staging, verify size/hash and supported compression before atomic replacement. Unsupported encryption/path mapping must remain explicit. If preflight fails, preserve saves and offer local-only launch.
5. Start the game directly. Report activity only for a verified live game process, including relevant children; helper lifetime is not gameplay.
6. After exit, snapshot changes, reread remote revision, upload with quota/error/concurrency checks and verify server state. Preserve pending work on failure.
7. Bind bridge journals to account, app and session. Use current server schemas/stat versions and submit only known earned events actually received from the game. Mark synchronized only after server confirmation.

The restore policy introduced in 0.7.0 prioritizes the newer copy after comparing content, as requested by the user. Equal dates with different content require resolution. Post-session upload additionally checks the remote state observed before launch so concurrent device changes are not resolved solely by timestamp.

## Historical milestones

### 0.6.4 — Read-only preflight

`-app <appid> -deck-cloud-inventory <file>` requests a complete Cloud.GetAppFileChangelist and UFS configuration. Exports include hashes, names, namespaces and revisions, not access URLs/headers. No download, upload or deletion occurred.

Swift validated account/app ownership and rejected partial deltas, unsafe paths and duplicates. A three-way planner did not mutate files. The initial real helper probe crashed with SIGSEGV/exit -11 before receiving a complete inventory; no saves changed. 53 automated tests passed. At this point, transfers, persistent activity and achievement submission were not implemented.

### 0.7.0 — Inventory and supported restore

Inventory loading became automatic. Authenticated staging downloads, SHA-1/size checks, supported Auto-Cloud mapping and backup receipts were added. Local/remote timestamp comparison followed content comparison. Player services read real Steam minutes/achievement counts separately from local time.

SDK-only cloud without recognized roots, encryption and complex path transforms remained unsupported. The CoreFoundation crash was traced to SteamKit's macOS hardware provider and addressed with a stable installation identity. Real BLUE REVOLVER statistics and staged downloads of five Cruelty Squad saves plus BLUE REVOLVER's main save were verified. Container replacement remained simulated; real saves were not overwritten. Files outside declared patterns, including BLUE REVOLVER replays, were excluded.

### 0.8.0 — Bridge, presence and activity

Pinned GSE x86/x64 Windows binaries were integrated with reversible preparation, backups and recovery. A watcher journals new earned events; ClientStoreUserStats2 preserves existing bits and requires server reread. Persona/GamesPlayed uses a persistent service with PID/parent and PlayingBlocked checks. Native achievement/cloud/Workshop views replaced embedded pages.

Real StoreStats transport was checked with an already-earned achievement, preserving progress and dates. The isolated Windows DLL test could not reach execution because wineserver/mach_port bootstrap failed in the restricted environment. New in-game capture and fullscreen notifications therefore remained unverified. Native macOS does not use these DLLs.

### 0.8.1–0.8.2 — Dependencies and diagnostics

External Steam installations gained direct native-bundle launching where unambiguous. Windows components were rechecked before launch, with official HTTPS Microsoft Visual C++ packages selected by PE architecture and verified prefix receipts.

Denshattack's installer log showed 0x80070666: a newer runtime was already installed. Exit code 102 is accepted only for Visual C++ when compatible registry entries and PE DLL versions are verified. x86 does not incorrectly require x64's vcruntime140_1.dll.

Logs distinguish monitor readiness, received events, popup creation/visibility and server confirmation. Local notification tests do not submit achievements. Watcher tests cover deduplication, unknown-name rejection and offline journals.

### 0.9.0–0.9.7 — Managed runtime

Runtime provisioning downloads verified upstream packages into staging and preserves container registry/module backups during migration. CrossOver discovery and mandatory external executable selection were removed. Metadata-only launch queries adopt installed games without reopening the store or redownloading payloads.

The final 0.9.7 configuration uses WineCX FOSS 24.0.7_7, supporting libraries and DXMT 0.80. It verifies Metal exports and Windows initialization. Sektori reached its menu on the development M1 on October 22, 2026. This does not certify other games, Steam synchronization or DX12 compatibility.

### 0.10.0 and later

Post-session Auto-Cloud upload, pending retries and explicit conflict resolution were implemented. Real testing completed a deduplicated unchanged-content cycle; newly generated progress across devices still needs full validation. Version 0.14.2 added one retry for failed inventory reads in a fresh session and safer disconnected-session handling, without automatically retrying writes through that mechanism.

## Acceptance checks for real gameplay

- Preflight returns the correct account, App ID and interpretable UFS metadata without the graphical client.
- Conflicting progress across devices preserves both copies until a choice.
- An interrupted transfer preserves recoverable originals and backups.
- New progress created on the Mac reaches a second device after confirmed upload; the reverse path is tested separately.
- An online session changes Steam's reported playtime without counting helpers, failed launches or unsupported offline time.
- An actually earned achievement reaches Steam without changing unrelated achievements or installing the official client.
- Direct launch remains usable when the service is offline or disabled, subject to game requirements.

## Primary references

- [Steam Cloud and Auto-Cloud](https://partner.steamgames.com/doc/features/cloud)
- [SteamAPI_Init requirements](https://partner.steamgames.com/doc/api/steam_api)
- [User statistics and achievements](https://partner.steamgames.com/doc/api/ISteamUserStats)
- [GameNative Steam service](https://github.com/utkarshdalal/GameNative/blob/master/app/src/main/java/app/gamenative/service/SteamService.kt)
- [GameNative Auto-Cloud](https://github.com/utkarshdalal/GameNative/blob/master/app/src/main/java/app/gamenative/service/SteamAutoCloud.kt)
- [SteamKit generated cloud messages](https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Base/Generated/SteamMsgCloud.cs)
- [Cruelty Squad store page](https://store.steampowered.com/app/1388770/Cruelty_Squad/)
