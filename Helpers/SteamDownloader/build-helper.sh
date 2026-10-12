#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOTNET=${MACGAMEDECK_DOTNET:-dotnet}
BUILD=${MACGAMEDECK_HELPER_BUILD:-"$HERE/build"}
RESOURCE="$HERE/../../Sources/MacGameDock/Resources"
"$DOTNET" publish "$HERE/Source/DepotDownloader/DepotDownloader.csproj" -c Release -r osx-arm64 --self-contained false -p:DebugType=None -o "$BUILD"
RUNTIME=$("$DOTNET" --list-runtimes | awk '$1 == "Microsoft.NETCore.App" && $2 ~ /^9\./ {gsub(/\[|\]/,"",$3); print $3 "/" $2}' | tail -1)
[ -n "$RUNTIME" ] || { echo 'A .NET 9 runtime is required for bundling.'; exit 1; }
DOTNET_ROOT=$(CDPATH= cd -- "$RUNTIME/../../.." && pwd)
mkdir -p "$RESOURCE/SteamRuntime/shared/Microsoft.NETCore.App" "$RESOURCE/SteamRuntime/host/fxr"
cp -R "$BUILD/" "$RESOURCE/SteamRuntime/"
cp -R "$RUNTIME" "$RESOURCE/SteamRuntime/shared/Microsoft.NETCore.App/"
cp -R "$DOTNET_ROOT/host/fxr/$(basename "$RUNTIME")" "$RESOURCE/SteamRuntime/host/fxr/"
cp "$DOTNET_ROOT/LICENSE.txt" "$DOTNET_ROOT/ThirdPartyNotices.txt" "$RESOURCE/SteamRuntime/"
codesign --force --sign - "$RESOURCE/SteamRuntime/DepotDownloader"
python3 "$HERE/hash-resources.py"
