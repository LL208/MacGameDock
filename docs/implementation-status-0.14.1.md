# Game focus and standalone distribution — 0.14.1

Real logs reported “Game window not identified” for Sektori, Denshattack and BLUE REVOLVER. Version 0.14.0 searched only the visible Space and original PID descendants, missing reparented Wine processes and windows on other Spaces. It also counted elapsed time after initial focus even when focus had been lost.

Discovery now includes fullscreen surfaces above the normal window level and all Window Server windows. Native libproc inspection replaces ps subprocesses. Wine window owners are matched using the exact WINEPREFIX and expected executable. Arguments are read only for same-user Wine window owners; only WINEPREFIX is retained from the environment, with no other values logged. C:/Z: paths and resolved Unreal targets are handled.

Foreground verification requires 2.5 continuous seconds on the same window. Window changes/focus loss reset it; the deadline is 45 seconds. After the first verified handoff, MacGameDeck hides to avoid covering the game with its own fullscreen Space. Home or game exit restores it. Reactivation no longer forces fullscreen. Similar Wine process names never authorize activating another container.

## Distribution and verification

A native Xcode Release app includes the icon/resources, verified ad hoc signature and standalone ZIP. It is not notarized for public distribution. Accessibility remains necessary for AX window management, and the app prepares the game runtime.

Tests cover argument parsing, container matching, C:/Z: paths, rejection of unrelated programs/containers and continuous focus with splash replacement. These do not replace a real two-monitor Wine game test.

Release 0.14.1 build 33 succeeded and its signature verified. Logic suite: 138 tests, 133 passed, 5 skipped, no failures. Stop any previous Xcode run before launching the Release app.
