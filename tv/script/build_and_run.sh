#!/usr/bin/env bash
set -euo pipefail
TV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--logs|--debug|--verify) ;; *) echo "Usage: $0 [run|--logs|--debug|--verify]" >&2; exit 2;; esac
TV_SIMULATOR_ID="${TV_SIMULATOR_ID:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "tvOS-27" in k for v in vs))')}"
xcrun simctl boot "$TV_SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$TV_SIMULATOR_ID" -b
xcrun simctl terminate "$TV_SIMULATOR_ID" com.chesstv.app 2>/dev/null || true
xcodebuild -project "$TV_ROOT/ChessTV.xcodeproj" -scheme ChessTV -configuration Debug \
  -destination "platform=tvOS Simulator,id=$TV_SIMULATOR_ID" -derivedDataPath "$TV_ROOT/.build" build
xcrun simctl install "$TV_SIMULATOR_ID" "$TV_ROOT/.build/Build/Products/Debug-appletvsimulator/ChessTV.app"
open -a Simulator --args -CurrentDeviceUDID "$TV_SIMULATOR_ID"
case "$MODE" in
  --logs) xcrun simctl launch --console "$TV_SIMULATOR_ID" com.chesstv.app ;;
  --debug) xcrun simctl launch --wait-for-debugger "$TV_SIMULATOR_ID" com.chesstv.app
    echo "Attach Xcode's debugger to ChessTV to continue." ;;
  --verify) xcrun simctl launch "$TV_SIMULATOR_ID" com.chesstv.app
    xcrun simctl spawn "$TV_SIMULATOR_ID" launchctl list | grep com.chesstv.app ;;
  *) xcrun simctl launch "$TV_SIMULATOR_ID" com.chesstv.app ;;
esac
