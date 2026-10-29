# Historical notes through 0.9.7

This edited English archive describes earlier releases, including approaches that were later replaced. It is not the current feature specification. See the [project README](../README.md) and [implementation reports](README.md).

## Early launcher and 0.4.x

The Swift/SwiftUI app targets Apple Silicon and macOS 13+. The repository/project is MacGameDock, while the scheme and built app are MacGameDeck. Xcode packages a native app; Package.swift supports logic tests. The Steam helper and .NET runtime are bundled.

### Session persistence

A cached profile/library is not a valid download session. Version 0.4.2 distinguished those states and required account.config to be saved before considering login successful. Tests covered receiving identity without credentials, preserving sessions after pause and reusing sessions after reopening.

Users migrating from 0.3 could optionally import the old Keychain session once, potentially triggering one unlock request, or sign in once with QR. Reconnect with QR deliberately forces new authentication.

The saved token lives under Account/steam-session.json with 0600 file and 0700 directory permissions. It is a credential, not a password, and is not separately encrypted from the disk. The data directory must never be published. Operations copy the session into private helper storage and remove the temporary copy afterwards. Tokens are retained as soon as login succeeds, even if later catalog/download work fails. Disconnect removes the new local session and account catalog; old Keychain entries are not read automatically. Steam revocation/expiry still requires login.

Version 0.4.1 corrected resource discovery for both flat SwiftPM/Finder layouts and Xcode's nested Contents/Resources/Resources layout, with tests for both.

### Platform choice and installation

Install checks store platforms/requirements, falling back to catalog platform metadata if the store is unavailable. A native Mac option does not prove compatibility with Apple Silicon; Intel ports may need Rosetta. Mac depots are requested as 64-bit and installed under Containers/Steam/APPID/macOS.

Windows games use Containers/Steam/APPID/prefix/drive_c/Program Files/MacGameDeck/Games/APPID. Steam metadata selects the executable. Each game gets a prefix and initialization checks. Supported Run Process dependencies run under the install directory; unsupported registry operations and external paths stop preparation. Escaping paths and launch symlinks are rejected.

Early releases did not provide Steamworks, achievements, cloud or client-dependent services. Epic/GOG supported local detection/import only. No title, including the first test candidate Nasty Zombies, was universally certified.

### Steam Families

Authenticated GetFamilyGroupForUser/GetSharedLibraryApps results merge eligible family games with owned licenses and retain provenance. If required metadata is unavailable, the previous catalog is preserved. Visibility does not grant a download license; depot authorization may reject shared titles. Shared-license downloading and Steamworks launching required further integration.

### Download queue

One download runs at a time. Completion, failure or pause advances the queue. Pausing preserves partial files and the session; resuming validates existing files instead of blindly redownloading. A running Windows dependency installer finishes its current step before pause.

downloads.json is written atomically. At this stage pending jobs reopened paused, requiring Resume. Jobs remain bound to their creating account. Queue pause affects waiting jobs; priority changes do not interrupt the active job. Cancellation retains partial files. Bandwidth limits and automatic updates were not yet implemented.

Speed/ETA use verified-byte progress and may vary during validation/decompression/preparation; they are not exact wire-traffic measurements. Artwork comes from Steam with local fallback.

### Estimates, data and verification

Requirements use published platform/RAM/GPU/DirectX information where available, with an approximate extra 2 GB Windows/Wine allowance. Suggested resolution/quality are generic starting points, not automatically applied profiles. FPS predictions require matched benchmarks and are not invented.

Data lives under ~/Library/Application Support/MacGameDock, including library.json, downloads.json, Account, Containers, Prefixes, Logs and Tools. Removing a catalog entry preserves game/save files; scans do not replace managed containers. MACGAMEDOCK_DATA_DIRECTORY provides isolated testing.

The build script supports MACGAMEDOCK_BUILD_DIR and MACGAMEDOCK_APP_OUTPUT, defaults to dist/MacGameDeck.app and signs ad hoc without notarization. App Sandbox is not enabled.

Initial validation passed 34 XCTest tests on Apple Silicon/Xcode 26.3, covering session reuse, pause, cleanup, private permissions, account mismatch, serial/persistent queue behavior, platform selection, family metadata and migration. Authenticated downloads/family entitlement and actual game launch were not exercised in that pass. Wine tests encountered server_mach_port restrictions.

## 0.5.0 — Controllers, activity and Workshop

GameController supplied discovery, wireless search, optional battery level and live input testing. A link opened system remapping settings. No controller driver or Steam Input equivalent was installed; Wine compatibility remained title-dependent.

Local process playtime was stored in playtime.json with 15-second checkpoints and exit updates. Native applications used NSRunningApplication monitoring. Process lifetime is not active engagement; it required the launcher to stay open and did not track unrelated launchers or surviving children. A crash could lose the last checkpoint interval; no offline duration was added after reopening.

At this stage, community pages used an embedded browser with temporary web data and independent web authentication. The download session was never exposed to it.

Workshop downloads verified item ownership/type and used Workshop/appid/itemid/download-uuid. Collections and unsupported content were rejected. Downloads preserved partial folders, did not subscribe/update automatically and were separate from the game queue. Installation copied into a new user-selected mod subfolder without overwriting or following symlinks. Archives, loaders and dependency activation were manual; the game had to be closed.

Achievements were read through official account statistics pages, without fabricated unlocks or promises of Steamworks integration.

## 0.6.0 — Official-client launching, later removed

This experimental release launched installed games through the official client using -silent -applaunch. Windows Steam was provisioned into the game's prefix; native Mac launching used the installed client.

Completed game downloads produced client-receipt.json with app/platform/build/depot manifests. Older installations recovered receipts by file validation. The launcher registered depots and linked the existing game folder into steamapps/common without intentionally duplicating it or overwriting unrelated manifests. Steam could subsequently validate/update its managed copy. A client restart could be necessary to read new manifests.

Downloader authentication was not official-client authentication. Separate containers could require Steam Guard/login. Tokens were not transferred between clients. The MostRecent account in loginusers.vdf was checked where available, without claiming it proved an online session.

Direct launch remained an explicit alternative. Client lifetime was not counted as game time. Validation passed 43 tests plus helper/runtime/release/signature checks, but did not validate real client login, Nasty Zombies gameplay or a newly earned achievement.

## 0.6.1 — Direct launch restored

Official-client integration caused Steam to reopen and request installation for already downloaded games, including Dead Estate and Cruelty Squad. It was removed. Play again launched the original executable, arguments and working directory in the existing prefix, without installing Steam or generating client manifests.

Games, saves and Steam folders created by 0.6.0 were preserved. Local playtime, downloader sessions, controllers and Workshop remained available. The achievements page was read-only. Game-imposed DRM/client requirements remained outside the launcher's control.

39 tests passed, including a real dummy-runtime process verifying direct executable/arguments without an account or generated client. Those tests did not launch Dead Estate or Cruelty Squad.

## 0.6.2 — Automatic Steam dependencies

The false “dependency 4.0 installer missing” error came from modern install scripts invoking .cmd wrappers while the resolver only accepted .exe/.msi. Standard wrappers now resolve their local payload and silent arguments; other batches use cmd. msiexec and INSTALLDIR expansion enforce paths within the game.

Preparation identifies readable dependency names, uses each installer's working directory and installs .NET before XNA. Missing CommonRedist families are downloaded from Steamworks Common Redistributables app 228980 with the saved session. Tools/CommonRedist caches complete supporting content without replacing existing game installers/scripts.

Completion markers are written only after success. Pause/error/retry preserve progress, and failed preparation never marks a game ready. Unsupported registry/external-path operations remain explicit rather than executed blindly. This installs supported runtime packages, not Windows GPU drivers, and does not guarantee game compatibility.

44 tests passed, including missing-package download, installer failure/retry and completed-step reuse. Read-only inspection resolved Blood and Bacon to .NET/XNA 4.0, and Nasty Zombies to DirectX June 2010 plus Visual C++ 2022 x64/x86; payloads already existed. Real Microsoft installers were not run during that verification.

## 0.6.3 — Wine initialization and diagnostics

Immediate prefix checks could run before wineboot finished writing registry files. Preparation waits up to 60 seconds for required files after process completion, supports cancellation and reports missing files on timeout. Containers and saves are not recreated. Structural validation is not a gameplay certificate.

Bounded preparation output records runtime, command and exit code in the game log without Steam authentication output. Failed downloads expose Open Log. Generic nw_read_request_report console timeouts do not by themselves identify the failing request or explain missing local Wine files.

47 tests passed, including delayed registries, timeout preservation and cancellation. Real containers were inspected read-only; games/installers were not launched.

## 0.6.4–0.6.5 — Cloud preflight

Read-only SteamKit2 inventory checks reused the saved session without Steam.app/steam.exe. A three-way planner recognized conflicts and protected deletions. No save, achievement or playtime synchronization was active yet. The initial live helper probe exited -11 without changing saves; 53 tests passed.

Version 0.6.5 added the missing UFS app-info section switch case that caused NotImplementedException after successful cloud requests. Missing UFS configuration no longer broke serialization. cloud_error sends bounded codes/types rather than raw URLs, headers or exception text. The UI distinguishes denied access, partial inventories and service failures instead of presenting unrelated download/disk errors. 54 Swift tests and a direct offline helper getter test passed.

See the [headless Steam architecture notes](steam-headless-sync.md).

## 0.7.0 — Steam statistics and Auto-Cloud restore

Cloud inventories load automatically with names, dates and sizes; deleted/forgotten entries are excluded. Before launching managed Steam games with an account, hashes and timestamps are compared. Identical files are skipped; missing/newer remote files are verified in staging and atomically restored after backup. Newer local content stays local.

Backups and restore.json live under Cloud/Backups/SteamID/AppID/UUID. Equal dates with different content, future timestamps, network failures or local edits during transfer stop automatic replacement and offer local-save launch. Deletions are not propagated.

Mapping supports declared common Windows/Wine roots, GameInstall and Mac roots with simple overrides/addpath/patterns. Unsafe paths, symlinks, ambiguous Wine profiles, unknown roots and pathtransforms are rejected. SDK-only cloud, encrypted files and non-HTTPS transfers are unsupported. Supported single-file ZIPs are size/hash checked. Temporary access URLs/headers stay inside the helper. Expired transfer requests retry at most three times.

Player.GetOwnedGames/GetAchievementsProgress provide actual Steam minutes/counts separately from local time. Missing data is not displayed as zero. This version did not submit new hours/achievements or upload local saves.

The helper crash was isolated to SteamKit's macOS hardware provider returning a null disk dictionary. A stable installation UUID in Account/steam-machine-id (0600) replaced that lookup, independent of account credentials. HTTP services do not share browser cookies.

61 tests passed. Live BLUE REVOLVER statistics were read without QR/client startup. Five Cruelty Squad saves and BLUE REVOLVER's main save were downloaded into temporary staging and verified, then staging was removed. Real saves were not replaced. BLUE REVOLVER replay files outside Auto-Cloud patterns remained visible but excluded from restore; if no files map, the app explains the limit and permits local launch.

## 0.8.0 — Native community and in-game Steam

SwiftUI replaced embedded achievement, cloud and Workshop pages. Achievements show icons, descriptions, earned/unearned filters and server dates. Cloud shows metadata/local presence. Workshop uses PublishedFile.QueryFiles search/pagination and individual downloads.

Downloads separate active work, waiting/interrupted jobs and history. Removing history never deletes game files; cancellation waits for actual worker exit before an active entry can be removed. Completion timestamps persist.

Steam sections show avatar/profile and eight Persona states. An internal SteamKit service uses private commands, atomic results, a distinct download LoginID and parent-exit shutdown. Presence persists per account, initially Offline; the official client is not installed.

Recognized Windows Steam API DLLs receive pinned GSE x86/x64 integration with original DLL/config backups and recovery receipts. Restore Original Steam API disables integration for that game; enabling it is explicit. Native Mac libraries, unknown libraries and EasyAntiCheat/BattlEye directories are not replaced. No SteamStub unpacker or DLC unlock-all is included.

Authenticated schemas initialize real achievement/stat state. Account-separated bridge data feeds a watcher accepting only known newly earned events from the session. Nonactivating popup requests and offline journals do not imply server confirmation. Submissions preserve existing bits, avoid resets, use fresh CRC and require server reread. GamesPlayed follows live monitored processes and respects PlayingBlocked; offline hours are not added retroactively.

70 Swift tests and helper protocol regressions passed. Live checks read profile/avatar, 41 BLUE REVOLVER achievements, 24 Terraria Workshop items and a StoreStats/reread round trip for an already-earned achievement without changing dates/progress. No new achievement was awarded.

The isolated Windows ABI test failed at wineserver/mach_port before loading the DLL. New in-game achievement capture and fullscreen popups remained unverified, with per-title SDK/DRM/multiplayer limits. GSE license, binary hashes and matching source archive are included.

## 0.8.1 — Automatic preparation

Local Steam manifests are rescanned at startup/return. Recognized installations show Play; a unique valid Mac bundle launches directly. At this historical stage ambiguous installations retained store launching.

Windows dependencies are rechecked before launch. Official Microsoft HTTPS Visual C++ 2015–2022 packages are selected by PE architecture, cached and verified via per-prefix DLL hashes/receipts. Older 2015+ scripts do not downgrade a newer runtime. Failures remain diagnostic rather than falsely declaring success.

## 0.8.2 — Logs and Visual C++ validation

Logs expose app/Steam/Wine events and the three latest per-container Visual C++ logs, with live refresh, filtering, copying and export. App logs rotate at 1 MB; views read bounded tails. Recognizable credentials are redacted, including exports.

Wine code 102 can be the truncated Visual C++ Windows 1638/0x80070666 downgrade result. Compatible registry entries, PE architecture and version must prove an installed runtime before acceptance. Runtime 14.44+ is recognized, including observed 14.51 in Denshattack. x86 does not require x64's vcruntime140_1.dll. Other installers or missing runtimes do not receive this exception.

Achievement logs separate monitor readiness, events, popup visibility and server confirmation. The local notification test never submits achievements. Simulated watcher tests verify deduplication/offline handling; real Windows capture remained unverified.

## 0.8.3 — Unreal executable resolution

Windows resources identify Unreal bootstrap targets: RCDATA 201 executable and RCDATA 202 arguments. Working directory/Steam arguments are retained. Targets must remain within the game, with no traversal/symlinks and matching architecture. Monitoring follows the actual game rather than only the short-lived bootstrapper.

At this historical stage the external CrossOver runtime environment included its Wine loader/libd3dshared and Rosetta AVX behavior. Available D3DMetal was selected for recognized x64 DirectX 12 executables. This approach was replaced by the managed runtime below.

Read-only Denshattack inspection resolved Denshattack_Proto/Binaries/Win64/Denshattack_Proto-Win64-Shipping.exe, retained its argument and identified D3D12. Exit code 41 alone did not establish the original crash cause; actual gameplay remained necessary.

## 0.9.0–0.9.7 — Autonomous Windows runtime

The final configuration automatically provisions WineCX FOSS 24.0.7_7 (about 164 MiB), supporting libraries (about 184 MiB) and DXMT 0.80 (about 18 MiB). Shared engine files coexist with separate per-game containers/saves. HTTPS packages use pinned size/SHA-256, verified caching, staging, atomic publication and previous-directory recovery.

CrossOver is not searched, copied or launched. Wine/Homebrew installation is unnecessary. Upstream archives/notices remain available; Rosetta 2 is still required for x86 execution. Steam features use the bundled helper, saved session and valid account/licenses. Metadata-only launch discovery adopts external games without steam:// fallback or payload redownload.

Container migration backs up registries before wineboot -u and preserves game/save files. DXMT handles DX10/11. Recognized Unreal games with a D3D11 module may use DX11 when no renderer is explicitly chosen, but module presence does not prove the project can run without DX12. Proprietary D3DMetal is not included. Client-dependent DRM, anti-cheat, DX12-only games and some native Steamworks games remain unsupported or unverified.

Real package download/hash/extraction and private Wine --version were checked, as were live Denshattack launch metadata. These checks did not prove rendering or gameplay.

Version 0.9.7 verifies actual Metal exports and Windows bootstrap in a test prefix, rather than treating extracted packages as a working runtime. Before engine migration, registry files and replaced Wine modules are backed up; native Microsoft DLLs/saves are preserved. The engine bootstrap log and Prepare and Verify Engine action expose diagnostics.

On October 22, 2026, engine bootstrap and Sektori container migration exited 0; DXMT launch reached the menu, confirmed by the user. This does not certify other games or Steam synchronization: a separate cloud timeout was also logged.

## Sources

- [Steam Families](https://partner.steamgames.com/doc/features/families)
- [Common redistributables](https://partner.steamgames.com/doc/features/common_redist)
- [Apple GameController](https://developer.apple.com/documentation/gamecontroller)
- [Steam achievements](https://partner.steamgames.com/doc/features/achievements)
- [Workshop](https://partner.steamgames.com/doc/features/workshop/implementation)
- [Visual C++ redistribution/version checks](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170)
- [Runtime source notices](../Sources/MacGameDock/Resources/RuntimeNotices/SOURCES.md)
