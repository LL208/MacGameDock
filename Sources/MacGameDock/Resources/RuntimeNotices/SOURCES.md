MacGameDeck downloads hash-pinned upstream artifacts directly from their publishers.

WineCX FOSS 24.0.7_7 (WS12 engine, open-source Wine fork; no CrossOver application required):
https://github.com/Sikarugir-App/Engines/releases/tag/v1.0
Wine source and patches (LGPL-2.1-or-later): https://github.com/Sikarugir-App/Sikarugir-foss-sources
Engine publisher and versions: https://github.com/Sikarugir-App/Engines
The upstream package is retained. DXMT DLLs and its Unix bridge are overlaid in the private engine directory.

DXMT 0.80 (MIT): https://github.com/3Shain/dxmt/tree/v0.80
https://github.com/3Shain/dxmt/releases/tag/v0.80
The accompanying LICENSE.DXMT is the unmodified upstream license.

Neither CrossOver nor Apple's proprietary D3DMetal files are copied or redistributed by this installer.

Third-party runtime libraries (including libinotify, GStreamer and MoltenVK) are copied from the hash-pinned Wine Staging 11.18 macOS package, excluding its Wine modules.
https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18
Build recipes and dependency sources: https://github.com/Gcenx/macports-wine
The complete upstream archive stays in the verified download cache.
