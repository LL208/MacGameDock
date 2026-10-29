# Usability implementation status — 0.10.0

This release implements an initial verifiable set of priorities, not every proposed expansion. This is a historical report.

| Feature | Status at 0.10.0 |
| --- | --- |
| Complete game page | Implemented; visually confirmed with an isolated library |
| Recent games, favorites, collections, hidden games, sorting | Implemented; preferences stored separately from the catalog |
| Launch stages and cancellation | Implemented, including contextual cloud errors |
| Process started vs. confirmed working | Implemented; per-game manual confirmation |
| Steam hours/achievements and server refresh | Implemented; a newly earned achievement still needs real-game validation |
| Auto-Cloud upload and offline recovery | Implemented; simulated tests and a real deduplicated upload cycle with identical content; new progress remains unverified |
| Explicit conflict resolution with backups | Implemented for supported Auto-Cloud paths |
| File and dependency repair | Implemented for installed Steam games |
| Disk selection, transfer and uninstall | Implemented with originals/backups retained; no automatic permanent deletion |
| Bandwidth limit and pause during play | Implemented; aggregate Steam block limit at next worker start |
| In-app download-ready notification | Implemented; background system notifications outstanding |
| Installed mods, disable/re-enable | Implemented; loaders, dependencies and load order outstanding |
| Onboarding, theme and larger text | Implemented; full VoiceOver/keyboard audit outstanding |
| Automatic game updates | Outstanding; manual repair/validation available |
| Backup cleanup and restoration UI | Open-folder actions available; full management outstanding |
| Per-game/chip graphics profiles and runtime rollback | Outstanding; no invented benchmarks |
| Measured FPS and frame pacing | Outstanding |
| Epic/GOG authentication and autonomous downloads | Outstanding; local detection/import available |
| Couch interface, gamepad navigation, input profiles | Outstanding at this version; controller detection/testing available |
| Developer ID signing, notarization, app updates | Not configured |

To validate new cloud progress: close the game on other devices, launch a supported Auto-Cloud title, create recognizable progress, exit, wait for confirmation, then check the second device. Preserve backups. A successful inventory read or deduplication response does not validate that scenario.
