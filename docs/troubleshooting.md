# Troubleshooting

| Problem | What to check |
|---|---|
| Nothing happens when I touch the bud | Is at least one AirPod out of your ear, and are they connected to this Mac? Is BudDial enabled in its menu? Settings shows a live dot that turns green when you cover the sensor. |
| A quick tap doesn't register | The AirPod needs a brief moment to notice your finger, so a feather-light flick may be missed. Rest your fingertip on the sensor for a beat. |
| The pill says "Nothing to undo" | Undo removes what BudDial typed since your last Return. It also stops if you typed or clicked since, because the cursor may have moved. |
| Undo doesn't work in a loud room | Background noise can sound like speech. Say "Scratch that" instead. |
| Text is copied but not typed | Allow Accessibility for BudDial in System Settings → Privacy & Security. |
| The orange microphone dot is always on | That is **Instant start**: BudDial keeps the last few seconds of audio in memory so your first words are not cut off. Turn it off in Settings if you prefer. |
| "Apple could not verify BudDial" | Expected for the downloaded app: see [opening it the first time](install.md#download-the-app). The Homebrew install avoids it. |

## Getting good results

- **Teach it your words.** Settings → Speech → **Vocabulary**: names and terms you say, like `Claude Code, Codex, GitHub`. About 20 words works best; a long list dilutes the hint.
- **Fix words it still gets wrong.** Settings → Speech → **Replacements**: "cloud coat" → "Claude Code". The corrected spelling is also added to the vocabulary.
- **Mind the room.** Your voice only has to beat the background noise at the Mac's microphone. A quieter room or sitting a little closer helps more than any setting.
- **Talk toward your Mac.** The AirPod is only the button; the Mac's microphone does the listening.

Still stuck? Settings → Diagnostics… shows what BudDial sees live, and `~/Library/Application Support/BudDial/events.log` records each touch and decision (timings only, never what you said). Open an [issue](https://github.com/teshnizi/BudDial/issues) with the relevant lines.
