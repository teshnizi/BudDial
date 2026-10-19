# How BudDial works

Measurements in this file come from the development Mac (AirPods 4 with ANC, MacBook Pro built-in microphone) in October 2026.

## The touch

AirPods report automatic ear detection to `bluetoothd`. BudDial runs `log stream` on bluetoothd's messages for the chosen AirPods and treats "in ear" on a bud that is out of the ear as a finger covering its sensor. Whichever bud changes state is the button.

- Delivery from bluetoothd to the app takes 2 to 9 ms.
- An idle AirPods link sits in Bluetooth sniff mode (441 ms interval), entered 20 s after the last activity, so a touch can reach the Mac up to about 0.45 s late. No public API keeps the link awake (name requests are cached, L2CAP opens are refused).
- The bud debounces its sensor. In 221 sensor changes the shortest uncovered gap ever reported was 549 ms. Two quick taps therefore arrive as one touch of 0.2 to 0.9 s, as two touches, or as a glitch, depending on timing. BudDial does not count taps.

### Gestures

| Touch | Speech | Result |
|---|---|---|
| Under 0.08 s | | Ignored (sensor glitch) |
| Shorter than the hold time (0.55 s) | | Tap: Return |
| Under 0.95 s | none, or no recognizable words | Tap: Return |
| 0.95 s to 4 s | none, or under 0.3 s with no recognizable words | Silent hold: remove the last dictation |
| 4 s or longer | none, or no recognizable words | Nothing: "No speech heard" |
| Longer than the hold time | yes | Dictation: transcribe and paste |

While a bud is held, the pill at the bottom of the screen says what letting go would do, by the same rules: **Release to send ↵** (blue) until the hold time, and while the sound stays under 0.3 s until 0.95 s; **Release to undo** (orange) from 0.95 s to 4 s while the sound stays under 0.3 s and there is a dictation to remove, or **Nothing to undo** (gray) when there is none (after a restart, a Return, or typing); **Listening** (red) once more sound than that is heard, and after 4 s in any case. A hold that long is someone thinking before they talk (5 of the first 52 silent-hold undos came from holds of 4 s or more), so it never removes anything. Every one of them keeps the live voice level bars, since the mic records from the moment of the touch. The speech it goes by is measured every 100 ms with the same analysis the release uses, over the first 15 s of a touch. Each change is logged ("Hint at 640 ms (speech 0.00 s): Release to send.").

- A tap within 1.5 s of a Return belongs to the same gesture and is ignored, so a double tap sends once. If text is still being transcribed, Return waits until it is pasted.
- "No speech" means less than 0.08 s above the noise floor, not counting the start cue. The cue comes back through the mic 100 to 200 ms after the touch; frames in the 0.6 s after the touch with at least half their power in its band (300 to 470 Hz) are skipped. Before that, the cue alone added 0.06 to 0.10 s to every touch, and silent holds failed in any room louder than about -45 dBFS. `tools/eval_speech_detection.sh` replays the benchmark takes mixed with fan noise, distant talkers and the cue: with the cue skipped and the 0.08 s cutoff, no silent hold or tap failed in a -43 dBFS room (about 50% before), and at -38 no tap and 7.6% of silent holds failed (about 50% before); single short words were missed 33% of the time at -43 and full sentences never. Silero speech detection was tried and lost on this mic: it missed about half of real sentences and counted the cue as speech.
- Of 10 short touches that reached transcription, 5 were taps the level meter mistook for speech (all at most 0.26 s); a short touch with no recognizable words now counts as a tap.
- Between 0.08 and 0.3 s of sound a touch may still be silent: noise or breath gave the user's silent holds up to 0.30 s. Whisper decides: no recognizable words means a tap (under 0.95 s), a silent hold (0.95 to 4 s), or nothing (4 s or longer); words are pasted. The user's shortest real replies ("Send it.", "Yes, go ahead.") measured 0.22 to 0.24 s and are recognized. The cost: a real dictation of 1 to 4 seconds that Whisper cannot make out at all removes the previous dictation (⌘Z in most apps brings it back). Takes this quiet are transcribed without the vocabulary and context prompt, which on near-silence made Whisper invent sentences ("I use the same as the other side."). Transcripts made only of hums ("Mhm. Mhm.") count as no words.
- Known limit: in rooms at about -36 dBFS or louder, the user's voice at the built-in mic was only 0 to 3 dB above the noise, and no detector tested separated them. Silent holds there can measure more than 0.3 s and read as speech; say "scratch that" instead.
- A silent hold removes the last dictation by backspacing it, and again for the one before, back to the last Return. It does nothing if another app is in front or you typed or clicked since BudDial's last keystroke (the cursor may have moved; macOS reports the time since the last physical key or click).
- Consecutive dictations into the same app are joined with a space until Return.

### Wearing

Both buds in ear means the AirPods are worn: any take in progress is discarded, and the sensor stays off until both buds are out again (re-seating one bud never starts listening). Known limit: when putting AirPods on one at a time, the first bud looks exactly like a finger cover, so listening starts and is silently discarded when the second bud goes in. A hold longer than 90 s is discarded, and that bud counts as worn until it leaves the ear.

### The stem

Stem presses reach the Mac only from a bud that is in an ear (as AVRCP play and pause, also delivered to the music app), and press-and-hold switches noise control. From a bud in the hand nothing arrives, so BudDial does not use the stem.

## Audio

- The Mac's built-in microphone is used, not the AirPod's: a bud out of the ear has no audio route, and opening its mic needs a Bluetooth profile switch of about 1.5 s.
- Instant start keeps the microphone open into a 3 s in-memory ring. A take starts 0.6 s before the touch event, so words spoken at the moment of the touch are kept. Pre-roll audio is kept only for speech that runs across the touch: the last pause of 200 ms or more before the touch cuts everything earlier. Nothing outside a committed take leaves memory. macOS shows the orange microphone dot while the mic is open; with Instant start off, the mic opens per touch and words before it opens are lost.
- Covering a bud makes macOS treat it as "in ear" and route system audio to it (A2DP start took 1.6 s in testing). Cues are therefore pinned to the Mac's built-in output, preloaded, and played off the main thread.
- Apple's voice processing (the path that enables Voice Isolation) was tested on 2026-10-16 and is not used. With the built-in mic pinned it works, and it lowered a -40 dBFS room's noise floor by 18 dB. But while it is active macOS processes playback as well: music in the AirPods sounded like a phone call, with less bass, at the same volume (the AirPods stayed at 48 kHz), and it stayed that way after the audio engine stopped, until the process released it. BudDial keeps the mic open all the time, so this would change everything the user hears. Turning it on only during a hold is untested.

## Speech

- whisper.cpp's `whisper-server`, bundled inside the app, runs for the life of the app with the model loaded and warmed: about 0.2 s per transcript, about 0.4 s from release to paste. After a long idle the first transcript can take 1.4 to 1.6 s.
- Default model: large-v3-turbo, 5-bit quantized (about 550 MB, downloaded once from Hugging Face on first launch and verified by SHA-256).
- Beam search (5) is on: 20 to 40 ms per take. Silero speech detection is off: it cut quiet speech in a noisy room and raised word errors by 11 to 25 points.
- Each take is sent with a prompt Whisper continues: "Words I use: <vocabulary>." plus up to 300 characters of the text before the cursor, read through Accessibility. Apps that hide their text fall back to what was dictated into them in the last 10 minutes. The prompt never leaves the Mac; the event log records only its length and source. A transcript that merely repeats the prompt, or one of Whisper's stock silence outputs ("Thank you.", "you", [BLANK_AUDIO]) on a take with little speech, is rejected.

### Benchmark (2026-10-15)

12 sentences read from a normal seat into the built-in mic, speech about 10 dB above a fan-like room floor of -43 dBFS. Word error rate, lower is better:

| Model | Vocabulary prompt, beam 5 |
|---|---|
| large-v3-turbo, 8-bit | 32% |
| large-v3-turbo, 5-bit (default) | 35% |
| large-v3 (full) | 43%, twice as slow |
| base.en | 72% |

Without the vocabulary prompt the default model scored 46%. Noise reduction before Whisper made it worse (49 to 58%); high-pass filtering and loudness normalization did not help. The remaining errors are words misheard through room noise, so the lever is the signal: a closer microphone or a quieter room.

To run it on your voice: Settings → Diagnostics… → Benchmark… shows 12 sentences; hold the bud and read each one. Takes are saved to `bench/<session>/` in the data folder, never transcribed or pasted. Then `./bench.py` (needs `brew install whisper-cpp`) runs every installed model × beam (1, 5) × speech detection (off, on) × vocabulary prompt (off, on) and prints word error rate, latency and the worst sentences.

## Pasting

The text goes on the clipboard, BudDial presses ⌘V, and the previous clipboard is restored 0.5 s later. Password fields are skipped. Without Accessibility the text is left on the clipboard instead.

## Signing and permissions

`build.sh` signs with a local self-signed identity kept in `signing/` (its keychain is added to the user search list and its certificate trusted for code signing once). macOS ties the Microphone and Accessibility grants to that certificate, so rebuilds keep them; an ad-hoc signature changes every build and silently loses them.

## Diagnostics

The data folder is `~/Library/Application Support/BudDial`:

- `config.json`: settings. Keys only there: `maximumHoldSeconds` (90), `preRollSeconds` (0.6), `vad` (false), `beamSize` (5), `showMonitorOnLaunch` (false).
- `events.log`: timings and decisions, never transcript text.
- `status.json`: live state.
- `whisper-server.log`: the speech engine's own log.
- `debug-clips/`: keeps audio only while its quota in `session.json` is above zero (default 0).

Settings → Diagnostics… shows the same live.
