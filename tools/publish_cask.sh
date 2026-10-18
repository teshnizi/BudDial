#!/bin/zsh
# Publishes the Homebrew cask for dist/BudDial.zip to github.com/teshnizi/homebrew-tap, so
# `brew install --cask teshnizi/tap/buddial` installs that release. Run it after `gh release create`.
# `tools/publish_cask.sh --print` only prints the cask.
#
# BudDial is signed but not notarized by Apple, so the cask clears macOS's quarantine flag after
# installing. Without that, the first launch stops at "Apple could not verify BudDial".
set -eu
root="${0:A:h:h}"
zip="$root/dist/BudDial.zip"
[[ -f "$zip" ]] || { echo "No dist/BudDial.zip: run tools/make_release.sh first." >&2; exit 1; }
version=$(unzip -p "$zip" BudDial.app/Contents/Info.plist | plutil -extract CFBundleShortVersionString raw -)
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

cask() {
    cat <<EOF
cask "buddial" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/teshnizi/BudDial/releases/download/v#{version}/BudDial.zip"
  name "BudDial"
  desc "Dictate into any app by holding an AirPod"
  homepage "https://github.com/teshnizi/BudDial"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "BudDial.app"

  # BudDial is signed but not notarized by Apple: without this, macOS blocks the first launch.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/BudDial.app"]
  end

  uninstall quit: "dev.buddial"

  zap trash: "~/Library/Application Support/BudDial"
end
EOF
}

if [[ "${1:-}" == "--print" ]]; then cask; exit 0; fi

checkout=$(mktemp -d)
trap 'rm -rf "$checkout"' EXIT
gh repo clone teshnizi/homebrew-tap "$checkout" -- --quiet
mkdir -p "$checkout/Casks"
cask > "$checkout/Casks/buddial.rb"
cd "$checkout"
if [[ -z "$(git status --porcelain)" ]]; then echo "The tap already has BudDial $version."; exit 0; fi
git add Casks/buddial.rb
git commit --quiet -m "buddial $version"
git push --quiet
echo "Published: brew install --cask teshnizi/tap/buddial installs BudDial $version"
