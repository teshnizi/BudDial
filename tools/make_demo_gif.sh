#!/bin/zsh
# Renders the welcome page's gesture animation (14 s loop) to docs/demo.gif. Needs ffmpeg.
set -eu
root="${0:A:h:h}"
src="$root/src"
fps=20
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[[ -d "$sdk_dir" ]] || sdk_dir=$(xcrun --show-sdk-path)
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -isysroot "$sdk_dir" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
    -framework AppKit -framework AVFoundation -framework IOBluetooth -framework ServiceManagement -framework QuartzCore \
    "$root/tools/render_welcome.m" "$src/OnboardingWindow.m" "$src/GestureStage.m" -o "$work/render"
mkdir -p "$work/frames"
"$work/render" "$work/frames" $fps
# Keep only the animation (hand, bud, spoken words, message box, pill): the README's own title and
# gesture table sit right next to it, so the guide's title and rows would repeat them.
crop="crop=iw:400:0:80"
ffmpeg -loglevel error -y -framerate $fps -i "$work/frames/f%04d.png" -vf "$crop,scale=640:-1:flags=lanczos,palettegen=stats_mode=diff" "$work/palette.png"
ffmpeg -loglevel error -y -framerate $fps -i "$work/frames/f%04d.png" -i "$work/palette.png" \
    -lavfi "$crop,scale=640:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "$root/docs/demo.gif"
ls -la "$root/docs/demo.gif"
