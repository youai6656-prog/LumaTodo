#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
if [[ "$developer" == */CommandLineTools ]]; then
    frameworks="$developer/Library/Developer/Frameworks"
    support="$developer/Library/Developer/usr/lib"
    swift test --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$support" "$@"
else
    swift test "$@"
fi
