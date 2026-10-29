# Contributing to MacGameDeck

Start with the [README](README.md) and [implementation reports](docs/README.md). The app is a development preview, and compatibility claims should be tied to reproducible evidence.

## Development

Open MacGameDock.xcodeproj, select MacGameDeck / My Mac and run in Xcode. Package.swift contains logic tests; native Xcode builds also compile the SwiftUI views.

Use an absolute MACGAMEDOCK_DATA_DIRECTORY for isolated tests. Never test save-file replacement, credential changes or destructive operations against another person's live data.

Keep pull requests focused. Explain the user-visible problem, resulting behavior and validation. If a test could not run, state that explicitly. A running process, successful build or downloaded file is not proof of working gameplay.

## Localization

The app supports Italian and English. Keep existing stored identifiers stable when translating labels. The English catalog is Sources/MacGameDock/Resources/Localization/en.json; preserve interpolation placeholders. Game names, file paths and raw diagnostic output should not be translated.

## Steam, cloud and dependencies

Preserve account boundaries, original game libraries and save backups. Never infer achievement unlocks, count helper lifetime as gameplay or resolve concurrent cloud edits without the established conflict checks.

Runtime packages must retain pinned integrity checks and source/license notices. Do not commit credentials, account sessions, personal libraries, saves or unredacted logs. Do not change third-party license texts.

## Reporting compatibility

Include the game/store/App ID, chip, macOS version, app commit, installation platform and runtime details. Report preparation, menu access and actual gameplay separately, along with tested controller, graphics and Steam-service behavior.
