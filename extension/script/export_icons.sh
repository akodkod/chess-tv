#!/bin/bash
# Export the shared Icon Composer artwork for browser extension manifests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ICON_TOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
for size in 16 32 48 128; do
  "$ICON_TOOL" "$ROOT/artwork/ChessTV.icon" --export-image \
    --output-file "$ROOT/extension/public/icons/icon-$size.png" \
    --platform macOS --rendition Default --width "$size" --height "$size" --scale 1 \
    --design-generation 27
done
"$ICON_TOOL" "$ROOT/artwork/ChessTV.icon" --export-image \
  --output-file "$ROOT/artwork/ChessTV.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 \
  --design-generation 27
cp "$ROOT/artwork/ChessTV.png" "$ROOT/extension/assets/chess-tv-icon.png"
