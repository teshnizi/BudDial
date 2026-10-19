# Developing BudDial

## Build

```sh
brew install whisper-cpp
./build.sh
```

`build.sh`:

1. runs the unit checks (`src/gesture_test.c`, `src/debug_clips_test.m`, `src/commands_test.m`);
2. compiles the app against the macOS SDK (the 26.5 Command Line Tools SDK when present: the 27.0 one ships broken `.tbd` stubs);
3. copies Homebrew's `whisper-server`, its libraries and ggml's backends into the bundle and rewrites their load paths, so the app runs without Homebrew;
4. signs everything with a local self-signed identity kept in `signing/` (created on the first run; macOS asks once to trust it). macOS ties the Microphone and Accessibility grants to that certificate, so rebuilds keep them;
5. installs to `~/Applications/BudDial.app`.

Quit and reopen the app after a build. The minimum macOS (26) comes from Homebrew's whisper.cpp, which is built for it; supporting older systems means building whisper.cpp from source with a lower deployment target.

## Test hooks

- `--onboarding` shows the welcome guide again.
- `--simulate-sensor` accepts fake input as the distributed notification `dev.buddial.simulate`, with object `cover` or `uncover` (a touch), `benchmark` (opens the benchmark panel), `onboarding:<step>` (0 to 4, with `--onboarding`), or `snapshot:<png path>` (renders the guide to a file, no Screen Recording permission needed).

## Tools

| Script | What it does |
|---|---|
| `tools/eval_speech_detection.sh` | Replays the benchmark takes mixed with noise, distant talkers and the start cue, and prints how often each speech detector misreads taps, silent holds and speech. |
| `./bench.py` | Word error rate and latency for every installed model, beam size, speech detection and vocabulary setting on your own recordings. Record them first: Settings → Diagnostics… → Benchmark…. |
| `tools/make_icon.sh` | Draws the app icon (`src/AppIcon.icns`, `docs/icon.png`) from the shared mark in `src/BudMark.m`. |
| `tools/make_hero_gif.sh` | Renders `tools/hero.html` (the README's animation; open it in a browser to watch it) to `docs/hero.gif` with WebKit, through `tools/render_hero.m`. Needs `ffmpeg`. |
| `tools/make_release.sh` | Builds from the committed source, checks the bundle, and packages `dist/BudDial.zip`. |
| `tools/publish_cask.sh` | Writes the Homebrew cask for `dist/BudDial.zip` to [teshnizi/homebrew-tap](https://github.com/teshnizi/homebrew-tap) (`--print` only prints it). |

## Releases

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `src/Info.plist` and commit.
2. `tools/make_release.sh` builds, verifies the signature, refuses to package if the bundle mentions your home folder or Homebrew paths, and writes `dist/BudDial.zip` with `ditto` (which keeps the signatures).
3. `gh release create v<version> dist/BudDial.zip --title "BudDial <version>" --notes-file <notes>`.
4. `tools/publish_cask.sh` points the Homebrew cask at the new release, so `brew upgrade --cask buddial` picks it up.

Releases are signed with the local identity in `signing/`, not an Apple Developer ID, so they are not notarized. The cask removes the quarantine flag after installing, so Homebrew users never see the "Apple could not verify" stop; people who download the zip click **Open Anyway** once (the README says how). Keep `signing/` backed up: macOS ties users' Microphone and Accessibility grants to that certificate, and a release signed with a different one makes everyone grant them again.

Testing a cask change before publishing: install it from a scratch tap (`brew tap-new`) with the `url` pointed at `file://…/dist/BudDial.zip` and `--appdir` set to a scratch folder, check the app has no `com.apple.quarantine` attribute, then delete the scratch folder and `/opt/homebrew/Caskroom/buddial` by hand. `brew uninstall` quits every running copy of BudDial, including your own build. `tap-new` turns on Homebrew's developer mode; turn it off afterwards with `brew developer off`.

## Data

Everything BudDial writes is in `~/Library/Application Support/BudDial`: `config.json` (settings), `models/`, `events.log` (timings and decisions, never transcript text), `status.json` (live state), `whisper-server.log`, and `bench/` (benchmark recordings). Settings → Diagnostics… shows the same live.

## Source map

| File | Role |
|---|---|
| `src/main.m` | App controller: gestures to actions, transcription, pasting, undo, voice commands, settings storage, menu |
| `src/Gesture.h` | Touch state machine (tap, hold, glitch, timeout) |
| `src/BudSensor.m` | Reads bluetoothd's log for the chosen AirPods' in-ear changes |
| `src/Recorder.m` | Always-open microphone ring, pre-roll, speech measure (start cue excluded) |
| `src/Transcriber.m` | Runs and talks to the bundled `whisper-server` |
| `src/ModelStore.m` | Downloads and verifies speech models |
| `src/Commands.m` | Voice commands and replacements |
| `src/OnboardingWindow.m`, `src/GestureStage.m` | Welcome guide and its gesture animation |
| `src/SettingsWindow.m`, `src/ReplacementsSheet.m` | Settings |
| `src/Overlay.m`, `src/Feedback.m` | The pill at the bottom of the screen, and the sound cues |
| `src/BudMark.m` | The BudDial mark, shared by the menu bar glyph and the app icon |
| `src/MonitorPanel.m`, `src/BenchmarkPanel.m`, `src/DebugClips.m` | Diagnostics, benchmark recording, opt-in audio clips |

How the touch is detected, why the Mac's microphone is used, and every measurement behind the thresholds: [how-it-works.md](how-it-works.md).
