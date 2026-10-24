#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), Swift Testing
# lives outside the default search paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
CLT_FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
if [[ "$DEV_DIR" == *CommandLineTools* && -d "$CLT_FRAMEWORKS/Testing.framework" ]]; then
    FLAGS=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
           -Xlinker -F -Xlinker "$CLT_FRAMEWORKS"
           -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS")
fi

swift test "${FLAGS[@]}" "$@"
