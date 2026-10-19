# Installing BudDial

You need a Mac with Apple silicon on macOS 26 or later, and AirPods with automatic ear detection (tested with AirPods 4).

## Homebrew

```sh
brew install --cask teshnizi/tap/buddial
```

Open BudDial from Applications and follow the welcome guide. Update with `brew upgrade --cask buddial`.

BudDial is not notarized by Apple yet. So that it opens without the "Apple could not verify" message, the cask removes the quarantine flag macOS puts on downloaded apps. The [cask](https://github.com/teshnizi/homebrew-tap/blob/main/Casks/buddial.rb) is one short file if you want to see exactly what it does.

## Download the app

1. Download [BudDial.zip](https://github.com/teshnizi/BudDial/releases/latest/download/BudDial.zip), double-click it, and drag **BudDial** into your **Applications** folder.
2. Open BudDial. macOS shows **"BudDial" Not Opened: Apple could not verify "BudDial" is free of malware**, because BudDial is not notarized yet. Click **Done** (not Move to Trash), then:
   - open **System Settings → Privacy & Security**,
   - scroll down to *"BudDial" was blocked to protect your Mac*,
   - click **Open Anyway**, enter your password or use Touch ID, and click **Open**.
3. Follow the welcome guide. You only do step 2 once.

## Build from source

You need Apple's command line tools (`xcode-select --install`) and [Homebrew](https://brew.sh):

```sh
brew install whisper-cpp
git clone https://github.com/teshnizi/BudDial.git
cd BudDial
./build.sh
open ~/Applications/BudDial.app
```

The first build asks once to trust a signing certificate it creates on your Mac, which keeps BudDial's permissions working each time you rebuild. A copy you build yourself is signed differently from the release, so macOS asks for the permissions again if you switch between them.

## What the welcome guide does

It asks for two permissions: **Microphone**, to hear you, and **Accessibility**, to type into other apps. Then it lets you pick your AirPods, test a touch, and try each gesture once in a practice box. In the background it downloads the speech model, about 550 MB, once.

## Uninstall

With Homebrew, quit BudDial from its menu and run:

```sh
brew uninstall --zap --cask buddial
```

`--zap` also deletes its settings and speech model. Without Homebrew, quit BudDial, then delete it from Applications and delete the folder `~/Library/Application Support/BudDial`. Either way, remove BudDial from System Settings → Privacy & Security → **Microphone** and **Accessibility**.
