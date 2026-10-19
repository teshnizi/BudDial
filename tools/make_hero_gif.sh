#!/bin/zsh
# Renders tools/hero.html (one 12.3 s loop) to docs/hero.gif, the README's hero animation. Needs ffmpeg.
set -eu
root="${0:A:h:h}"
fps=20
loop=12.3
# GitHub shows only the first frame to people who turn off animation, so start where it explains the most:
# the bud held, every word said, "Listening" on screen.
start=5.7
width=1200
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[[ -d "$sdk_dir" ]] || sdk_dir=$(xcrun --show-sdk-path)
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -isysroot "$sdk_dir" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
    -framework AppKit -framework WebKit "$root/tools/render_hero.m" -o "$work/render"
mkdir -p "$work/frames"
"$work/render" "$root/tools/hero.html" "$work/frames" $fps $loop $start
scale="scale=$width:-1:flags=lanczos"
ffmpeg -loglevel error -y -framerate $fps -i "$work/frames/f%04d.png" -vf "$scale,palettegen=max_colors=256:stats_mode=full" "$work/palette.png"
ffmpeg -loglevel error -y -framerate $fps -i "$work/frames/f%04d.png" -i "$work/palette.png" \
    -lavfi "$scale [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 "$root/docs/hero.gif"
ls -la "$root/docs/hero.gif"
