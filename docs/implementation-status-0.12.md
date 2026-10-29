# Artwork and layout — 0.12.0

Big Picture adds an adaptive portrait-cover grid, selected-game background/logo, section bar and compact controls. PC Mode, the desktop Big Picture button and ⌘⇧B switch interfaces. Extended-controller View/Share also switches while the app is foreground. The preference persists.

SteamGridDB provides covers, landscapes, backgrounds and logos using a personal API key, entered in desktop Settings or through a masked Big Picture keyboard. The key is stored privately (0600 file, 0700 directory), excluded from source/logs and never sent to image CDNs. Requests are limited to four concurrent operations with timeouts, byte limits and pixel limits.

Steam games match by App ID; other stores require a unique normalized-title match. Static assets are selected automatically, excluding NSFW/humor entries and preserving attribution. Managed disk cache: 256 MiB. Decoded image cache: 96 MiB/64 entries. Offline/failed refresh preserves existing artwork. Steam images or placeholders provide fallback.

## Verification

122 logic tests: 117 passed, 5 skipped. Run in Xcode and again from the terminal with a non-aliased temporary directory. Tests cover simulated API requests, authorization headers, CDN downloads without credentials, offline caching, failed-refresh preservation, asset filters and credential permissions.

Native Xcode compilation succeeded. Real SteamGridDB access requires the user's key and was not verified against a live account. Steam images downloaded in an isolated test library. Full visual review and real interface switching were not certified because accessibility inspection timed out or failed. Test copies remain separate from real user data.
