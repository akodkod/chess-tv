#!/usr/bin/env bash
set -euo pipefail
MAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION=5700f127e38dd53c4735ea23ef743b4b538eacd4
SOURCE="$MAC_ROOT/.generated/transcribe-runtime"
FRAMEWORK="$SOURCE/bindings/swift/build-apple/TranscribeCpp.xcframework"
if [[ -f "$MAC_ROOT/.generated/speech-runtime-revision" ]] && [[ "$(cat "$MAC_ROOT/.generated/speech-runtime-revision")" == "$REVISION" ]] && [[ -d "$FRAMEWORK" ]]; then exit 0; fi
if [[ ! -d "$SOURCE/.git" ]]; then
  git clone --no-checkout https://github.com/handy-computer/transcribe.cpp.git "$SOURCE"
fi
if ! git -C "$SOURCE" cat-file -e "$REVISION^{commit}" 2>/dev/null; then
  git -C "$SOURCE" fetch --depth 1 origin "$REVISION"
fi
git -C "$SOURCE" checkout --detach "$REVISION"
if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  if [[ ! -x "$MAC_ROOT/.build/runtime-tools/bin/cmake" ]]; then
    python3 -m venv "$MAC_ROOT/.build/runtime-tools"
    "$MAC_ROOT/.build/runtime-tools/bin/pip" install cmake==3.31.6 ninja==1.11.1.3
  fi
  export PATH="$MAC_ROOT/.build/runtime-tools/bin:$PATH"
fi
TRANSCRIBE_XCFRAMEWORK_SLICES=macos bash "$SOURCE/scripts/ci/build_xcframework.sh"
printf '%s\n' "$REVISION" > "$MAC_ROOT/.generated/speech-runtime-revision"
