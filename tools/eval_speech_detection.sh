#!/bin/sh
# Build and run the speech-detection evaluation; the binary lives in a temp dir that is removed.
# Usage: tools/eval_speech_detection.sh [bench session dir]
set -e
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prefix=$(brew --prefix 2>/dev/null || echo /opt/homebrew)
# Same SDK choice as build.sh: the Command Line Tools' 27.0 SDK ships malformed .tbd stubs.
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$sdk_dir" ] || sdk_dir=$(xcrun --show-sdk-path)
clang -isysroot "$sdk_dir" -O2 -Wall -Wextra -o "$tmp/eval" "$here/eval_speech_detection.c" \
    -I"$prefix/include" -L"$prefix/lib" -lwhisper -lggml -lggml-base -Wl,-rpath,"$prefix/lib"
"$tmp/eval" "$@"
