#!/bin/zsh
# Regenerates src/AppIcon.icns and docs/icon.png from tools/make_icon.m.
set -eu
root="${0:A:h:h}"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[[ -d "$sdk_dir" ]] || sdk_dir=$(xcrun --show-sdk-path)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -isysroot "$sdk_dir" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -framework AppKit "$root/tools/make_icon.m" -o "$work/make_icon"
mkdir -p "$root/docs"
"$work/make_icon" "$work/AppIcon.iconset" "$root/docs/icon.png"
iconutil -c icns "$work/AppIcon.iconset" -o "$root/src/AppIcon.icns"
echo "Wrote src/AppIcon.icns and docs/icon.png"
