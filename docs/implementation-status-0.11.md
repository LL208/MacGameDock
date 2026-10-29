# Controller interface — 0.11.0

Big Picture is enabled by default and can be disabled in Settings. Desktop mode retains an action to return to the controller interface.

## Coverage

- Home, library, search, filters, favorites, collections, hidden games and pagination.
- Game pages: launch/return, Mac/Windows selection, maintenance, transfer, uninstall with backup and confirmed catalog removal.
- Download queue/history, priority, pause/resume and cancellation.
- Steam account/QR login, presence, achievements, cloud and explicit conflict resolution.
- Workshop search/download, mod folder selection and activation/deactivation.
- Settings, library detection, disk selection, game import and log viewing/export.
- Internal keyboard and folder browser for these controller workflows.

## Input

GameController recognizes macOS-supported extendedGamepad or microGamepad profiles, not every arbitrary HID device. Symbols come from the device profile, with generic fallbacks. The most recently used controller becomes active. Reconnection does not execute a button that was already held.

The persistent Confirm/Back swap changes launcher inputs and hints, not game controls. Physical keyboard Enter/Escape retain their meanings. Directional repeat starts after 380 ms and repeats every 110 ms. Action buttons require a new press. Stable IDs preserve selection, and destructive confirmations default to Cancel.

Ordinary background input does not navigate the launcher. Holding Menu for 1.2 seconds requests a return to the app without closing the game. Bluetooth pairing, system permissions and Steam Guard use their respective interfaces. Virtual controllers and per-game Steam Input profiles are not implemented. Input inside Wine games depends on the runtime and title.

## Verification

117 logic tests: 112 passed, 5 skipped, no failures. Native Xcode build succeeded. Automated coverage includes focus, incomplete grids, repeat, reconnection, history, confirmations, inversion and existing preference compatibility.

An isolated UI test covered full screen, game details, on-screen search, folders and updated hints after inversion. A DualShock 4 was detected and PlayStation symbols displayed. Returning from an actual game with Menu still requires physical validation; device detection does not prove that workflow.
