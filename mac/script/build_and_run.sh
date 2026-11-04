#!/usr/bin/env bash
set -euo pipefail
MAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--logs|--debug|--telemetry|--verify) ;; *) echo "Usage: $0 [--logs|--debug|--telemetry|--verify]" >&2; exit 2;; esac
"$MAC_ROOT/script/prepare_speech_runtime.sh"
pkill -x ChessTVMac >/dev/null 2>&1 || true
xcodebuild -project "$MAC_ROOT/ChessTVMac.xcodeproj" -scheme ChessTVMac \
  -configuration Debug -derivedDataPath "$MAC_ROOT/.build" build
MAC_APP="$MAC_ROOT/.build/Build/Products/Debug/ChessTVMac.app"
case "$MODE" in
  --debug) lldb -- "$MAC_APP/Contents/MacOS/ChessTVMac" ;;
  --logs|--telemetry)
    open -n "$MAC_APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "ChessTVMac"' ;;
  --verify)
    open -n "$MAC_APP"
    sleep 1
    pgrep -x ChessTVMac >/dev/null ;;
  *) open -n "$MAC_APP" ;;
esac
