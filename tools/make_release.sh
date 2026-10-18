#!/bin/zsh
# Builds BudDial from the committed source and packages it as dist/BudDial.zip for a GitHub release.
# Releases are signed with the identity in signing/; keep it backed up: a release signed with another
# certificate makes macOS ask every user for the Microphone and Accessibility permissions again.
set -eu
root="${0:A:h:h}"
cd "$root"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first: a release is built from the committed source." >&2; exit 1; }
./build.sh
app="$HOME/Applications/BudDial.app"
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
codesign --verify --strict --deep "$app"
# Nothing personal or machine-specific may ship in the bundle.
for needle in "$HOME" "/opt/homebrew"; do
    if found=$(grep -rlaF "$needle" "$app"); then echo "The bundle mentions $needle in:" >&2; echo "$found" >&2; exit 1; fi
done
mkdir -p dist
rm -f dist/BudDial.zip
ditto -c -k --sequesterRsrc --keepParent "$app" dist/BudDial.zip   # keeps the code signatures intact
shasum -a 256 dist/BudDial.zip
echo "BudDial $version packaged: dist/BudDial.zip (commit $(git rev-parse --short HEAD))"
