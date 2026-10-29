# Permission prompts and cloud recovery — 0.14.2

Game launch now reads Accessibility status without requesting permission. Only the explicit “Enable window and display management” action in the session menu can request the macOS dialog. Launch does not depend on this permission; AX movement/control still requires system authorization.

Current builds are signed ad hoc. No Developer ID identity is available on the development Mac. This change does not claim to fix permission persistence between differently signed builds and does not alter system security settings.

Earlier Steam Cloud logs showed NullReferenceException before launch. Isolated inventories for Cruelty Squad, BLUE REVOLVER and Sektori succeeded; the original exception was not reproduced. A SteamID access after an await was corrected: identity is captured before the request, and disconnection produces a specific error. Inventory reads failing with connection, timeout or NullReferenceException receive one retry in a fresh session. Cloud writes are not automatically retried by this recovery mechanism. Integrity, account and conflict checks remain active.

Engine exceptions include method names without paths, arguments or credentials; the app filters and bounds those names. A full launch-path test simulates initial disconnection and verifies remote-save availability before game execution. C# tests cover a disconnected session without SteamUser: a connection error replaces NullReferenceException and no inventory is written.

Verification: native Xcode Release build succeeded; 138 Swift tests, 5 skipped, no failures; C# regressions passed. App/ZIP 0.14.2 build 34 passed signature/archive checks. Disappearance of repeated dialogs during real gameplay on the user's Mac remains to be verified.
