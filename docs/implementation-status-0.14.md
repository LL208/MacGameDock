# In-game session menu — 0.14.0

The launcher captures its window's display before asynchronous preparation. The coordinator waits for a visible window belonging to the launched process or descendants, attempts movement to that display and checks foreground status. At this version discovery is limited to 20 seconds. New requests or opening the menu cancel previous work; cancelled tasks do not change the next handoff. Unrelated Wine/wineserver processes are never activated or terminated by name.

Handoff disables Big Picture navigation. Held buttons must be released before menu actions can fire. Home opens a nonactivating panel with controller navigation in both interfaces; holding Menu for 1.2 seconds is the fallback. Home/Back resume, L1/R1 change sections.

The menu includes session time, last-read Steam hours, automatically refreshed account-scoped achievements, macOS remapping, Confirm/Back inversion and confirmed exit. Normal exit uses an accessible close action or app termination request; explicit force termination targets only the tracked process. Exit triggers existing hours/cloud updates.

## Limits

The panel neither injects into the renderer nor pauses the game. Exclusive fullscreen may cover it or refuse movement. Accessibility is required for AX window movement/raising/closing and must be granted by the user. Home can be reserved by macOS. Runtime-connected controllers may continue sending input to the game while the panel is open. A system-settings link does not emulate Steam Input or guarantee Wine remapping.

## Verification

Tests cover screen coordinate conversion, oversized-window fitting, descendant filtering, nonrepeating Home, long Menu press, short-press cancellation and held-button guards. Xcode compiles the SwiftUI panel; the logic harness omits it with other views. Real dual-monitor/controller gameplay still needs validation.

Native Xcode 0.14.0 build 32 succeeded. Logic suite: 133 tests, 128 passed, 5 skipped, no failures. An earlier SteamSocial fixture timed out during compilation; the complete rerun after compilation passed.
