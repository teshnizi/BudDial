<p align="center"><img src="docs/icon.png" width="128" alt="BudDial icon: an earbud shaped like a speech bubble"></p>

<h1 align="center">BudDial</h1>

<p align="center"><b>Type with your voice by holding an AirPod.</b><br>
A small Mac menu bar app. Your speech becomes text on your Mac; nothing is uploaded.</p>

<p align="center"><img src="docs/demo.gif" width="560" alt="A finger holds a bud while the words are spoken, a tap sends them, and a silent hold removes the next dictation"></p>

## How you use it

Take one AirPod out of your ear and hold it like a button.

| Do this | What happens |
|---|---|
| **Cover the sensor and talk** | When you let go, what you said is typed where your cursor is, in any app. |
| **Tap** | Presses Return, so a chat message gets sent. |
| **Cover it for a second without talking** | Removes what you just dictated. Do it again to remove the one before. |

While you hold the bud, a small pill at the bottom of the screen tells you what letting go will do: **Release to send**, **Listening**, or **Release to undo**.

Two things to know:

- **Talk toward your Mac.** The AirPod is only the button; the Mac's own microphone does the listening, so speak as you would to the screen.
- **Keep wearing the other bud if you like.** While *both* AirPods are in your ears, BudDial leaves them alone, so music and calls work as usual.

### Voice commands

Start what you say with one of these:

| Say | What happens |
|---|---|
| "Spotlight Claude Code" | Opens Spotlight and types "Claude Code". Tap to open the result. |
| "Scratch that" | Removes the last dictation. |
| "New line" | Adds a line break without sending. |

## Install

**You need** a Mac with Apple silicon running macOS 26 or later, and AirPods with automatic ear detection (tested with AirPods 4).

There is no prebuilt download yet. Building it takes a few minutes:

1. Install Apple's command line tools (`xcode-select --install`) and [Homebrew](https://brew.sh).
2. Build and open BudDial:

   ```sh
   brew install whisper-cpp
   git clone https://github.com/teshnizi/BudDial.git
   cd BudDial
   ./build.sh
   open ~/Applications/BudDial.app
   ```

   The first build asks once to trust a signing certificate it creates on your Mac. That keeps BudDial's permissions working each time you rebuild.
3. A short welcome guide does the rest: it asks for the microphone and Accessibility permissions (Accessibility is how BudDial types into other apps), lets you pick your AirPods and test a touch, and has you try each gesture once. In the background it downloads the speech model, about 550 MB, once.

After that, BudDial lives in the menu bar: the bud with three dots. Settings, Disable and Quit are in its menu.

## Getting good results

- **Teach it your words.** Settings → Speech → **Vocabulary**: names and terms you say, like `Claude Code, Codex, GitHub`. About 20 words works best; a long list dilutes the hint.
- **Fix words it still gets wrong.** Settings → Speech → **Replacements**: "cloud coat" → "Claude Code". The corrected spelling is also added to the vocabulary.
- **Mind the room.** Your voice only has to beat the background noise at the Mac's microphone. A quieter room or sitting a little closer helps more than any setting.
- **Short taps count.** A tap is any short touch. The AirPod needs a brief moment to notice your finger, so a feather-light flick may not register.

## Troubleshooting

| Problem | What to check |
|---|---|
| Nothing happens when I touch the bud | Is at least one AirPod out of your ear, and are they connected to this Mac? Is BudDial enabled in its menu? Settings shows a live dot that turns green when you cover the sensor. |
| The pill says "Nothing to undo" | Undo removes what BudDial typed since your last Return. It also stops if you typed or clicked since, because the cursor may have moved. |
| Undo doesn't work in a loud room | Background noise can sound like speech. Say "Scratch that" instead. |
| Text is copied but not typed | Allow Accessibility for BudDial in System Settings → Privacy & Security. |
| The orange microphone dot is always on | That is **Instant start**: BudDial keeps the last few seconds of audio in memory so your first words are not cut off. Turn it off in Settings if you prefer. |
| Wrong words | Add them to Vocabulary or Replacements (see above). |

## Privacy

- Speech is turned into text on your Mac by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Nothing is sent anywhere.
- The microphone audio stays in memory and is discarded unless you are holding a bud.
- To spell names right, BudDial reads up to 300 characters before your cursor and gives them to the speech model on your Mac. You can turn this off in Settings (**Use text before the cursor**).
- The event log records timings, never what you said.
- The only network access is the one-time download of the speech model from Hugging Face.

## How it works

AirPods tell macOS when they go in or out of an ear. BudDial watches that signal for your AirPods, so a fingertip on the sensor of a bud in your hand looks like "in ear": that is the button. The length of the touch and whether you spoke decide the gesture. The Mac's microphone records, including the moment just before your touch, and a speech engine kept running on your Mac types the result about half a second after you let go.

The details, measurements and known limits are in [docs/how-it-works.md](docs/how-it-works.md).

## Uninstall

Quit BudDial from its menu, delete `~/Applications/BudDial.app` and `~/Library/Application Support/BudDial`, and remove BudDial from System Settings → Privacy & Security → Microphone and Accessibility.

## Development

How the build works, test hooks, the benchmark and the source layout: [docs/development.md](docs/development.md).
