# How Voice Note Transcriber works

This page is for the curious and for contributors. To install the app, see the [README](../README.md).

## Architecture

```
Voice Note Transcriber.app (SwiftUI)               TranscriberCore (no UI, unit-tested)
├─ Drop target: window, Dock icon, Open With       ├─ AudioLoader    any audio → 16 kHz mono PCM
├─ TranscriptionQueue: one file at a time ──────▶  ├─ Chunker        split at pauses, ~4-minute parts
├─ Sidebar = the notes folder (FolderWatcher)      ├─ WAV            each part → WAV for upload
└─ Settings: key, model, strictness, folder,       ├─ OpenAIClient   transcribe each part, write a title
   format, prompt                                  ├─ InaudibleMarker doubtful words → [inaudible]
                                                   ├─ Stitcher       join the parts
transcriber-cli (the same pipeline, in Terminal)   ├─ NoteWriter     details header, file name, rename
                                                   ├─ NoteLibrary    read notes back from the folder
                                                   └─ Keychain       the API key
```

| Folder | What's in it |
|---|---|
| `Sources/TranscriberCore` | Everything that isn't UI. `TranscriptionPipeline` runs the steps below in order |
| `Sources/VoiceNoteTranscriber` | The SwiftUI app: window, queue, note views, Settings, folder watcher, and a debug-only screenshot renderer |
| `Sources/transcriber-cli` | A command-line twin of the app, for trying the pipeline on real files |
| `Tests/TranscriberCoreTests` | Unit tests (Swift Testing). No network; temporary files only |
| `install.sh`, `scripts/`, `Resources/Info.plist` | Builds the `.app` bundle, draws the icon, renders the README screenshots |

There are no third-party dependencies: AVFoundation decodes audio, URLSession talks to OpenAI and Security stores the key.

## The pipeline

1. **Decode.** `AVAssetReader` converts the file to 16 kHz mono 16-bit PCM in memory, so anything AVFoundation can read works without a conversion step: m4a/AAC from Voice Memos, mp3, wav, aiff, caf, and the soundtrack of mp4 or mov video. A 25-minute note decodes in under a second.
   The recording date comes from the date the iPhone stores inside the file, falling back to the file's creation date.
2. **Split at pauses.** Recordings up to 5½ minutes are sent whole. Longer ones are cut into parts of about 4 minutes (between 2 and 5½), always inside a pause, so no word or sentence is cut in half:
   - The audio is measured in 100 ms frames (dBFS).
   - A frame counts as quiet if it's below the *lower* of two thresholds: the recording's 10th-percentile level + 6 dB, or the quietest moment in the stretch where the cut can fall + 8 dB. The second one matters for recordings with few pauses, where the 10th percentile is already speech.
   - Each pause of at least 0.3 s is scored by its length, with a small penalty for distance from the 4-minute mark, and the cut goes in the middle of the best one. With no pause at all, it goes at the quietest moment.

   On a real 24m 49s walking note this gave seven parts, every cut in silence.
3. **Transcribe.** Each part is encoded as WAV and sent on its own:
   - `gpt-transcribe` (default) uses `/v1/audio/transcriptions` with `include[]=logprobs`, then `InaudibleMarker` replaces the words it wasn't sure of (see below).
   - `gpt-audio-1.5` gets the part as `input_audio` in a Chat Completions request, with your prompt as the system message and `modalities: ["text"]`.
   - Requests are retried up to three times on rate limits (not on an exhausted quota), server errors and dropped connections, honouring `Retry-After`.
4. **Join.** `Stitcher` drops parts that came back as `[no speech]` and joins the rest: with a paragraph break if the previous part ended a sentence, or a space if it stopped mid-sentence.
5. **Title.** `gpt-5-mini` writes a short title from the transcript. If that fails, the audio file's name is used and the note shows a warning.
6. **Save.** The note is written as `yyyy-MM-dd HH.mm – Title.md` (or `.txt`), with ` (2)` added if the name is taken.

## Marking [inaudible]

`gpt-transcribe` takes no instructions, so it can't be told not to guess. Instead it's asked for the log probability of every token it writes, and the app does the marking:

- A word is a whitespace-separated run of text. Its confidence is the **product** of the probabilities of the tokens that spell its letters and digits, so a made-up word built from several half-sure tokens ("Wondermushly": 0.6 × 0.6 × 0.6…) scores low even when no single token does. Punctuation tokens don't count: being unsure whether to end a sentence isn't being unsure what was said.
- A word below the threshold for **Mark as [inaudible]** in Settings (Light 30%, Balanced 50%, Strict 70%) becomes `[inaudible]`, keeping its punctuation. Neighbouring doubtful words in the same phrase become one `[inaudible]`, but not across a full stop, comma or line break.
- The text OpenAI returns has spaces between sentences that the tokens don't, so text and tokens are lined up ignoring whitespace. If they differ in anything else, the tokens' own text is used, because that's what the probabilities describe.
- Markers the model writes itself, like `[unclear]` or `(inaudible)`, become `[inaudible]`.
- If the response has no probabilities, the part fails with an error saying so, rather than silently passing on unmarked guesses. **Off** skips all of this.

On a real 22-minute walking note, Balanced marked 47 stretches in 3,356 words.

### Why not gpt-audio-1.5

It was the original default, because it follows a prompt that says "never guess". In testing on that same note it was unreliable: across ten requests, replies came back wrapped in JSON (`{"text": "…"}`), started with stray internal tokens (`<|aesthetics_7|>`), were empty, or covered 141 words of a part that held about 700. Its wording of hard passages also changed from run to run, so it was guessing despite the prompt. It's still selectable for comparison.

## The prompt

Only `gpt-audio-1.5` uses the prompt. The default (`DefaultPrompt.swift`, editable in Settings when that model is selected) asks for **clean verbatim**:

- The speaker's exact words in their order, never paraphrased or corrected.
- No ums, stutters, repeated words or abandoned false starts.
- Punctuation, and paragraphs at changes of thought. British spelling.
- **Never guess.** Anything unclear becomes `[inaudible]`, one per unclear stretch, even when a guess seems likely.
- No text for wind, traffic or silence. Other voices go on their own line as `Other speaker:`.
- Only the transcript, or exactly `[no speech]` if there's none.

The app relies on `[inaudible]` (it's highlighted in the window) and `[no speech]` (silent parts are dropped), so keep both if you edit the prompt. Square brackets are used because `<inaudible>` disappears in Markdown previews.

## Notes and the library

Each note starts with a details header. Markdown notes use front matter, which Obsidian and most editors understand:

```markdown
---
recorded: 2026-11-10 14:32
duration: 24m 49s
source: "New Recording 23.m4a"
model: gpt-transcribe
---

So the opening should start with her already on the stairs…
```

Plain-text notes use `Recorded:`, `Duration:`, `Source:` and `Model:` lines instead.

The notes folder is the library; the app keeps no database.

- On launch, on every return to the app, and whenever the folder changes (a `DispatchSource` watcher, debounced by 250 ms), `NoteLibrary` re-reads the folder (not subfolders).
- Only files with the app's header (`source` and `model`) are listed, so the folder can be shared with other notes.
- The date and length come from the header, so a note renamed in Finder keeps its date, with or without the date at the front of its name.
- Editing a title in the app renames the file. Renames, moves and deletions in Finder show up straight away.

## Privacy and storage

| What | Where |
|---|---|
| Your OpenAI API key | The login Keychain: service `VoiceNoteTranscriber`, account `openai-api-key` |
| Settings | `UserDefaults` for `local.voicenotetranscriber` |
| Notes | The folder you choose (default `~/Documents/Voice Notes`) |
| Audio | Read where it is and never copied. Sent to OpenAI only as the WAV parts above |

The only network requests go to `api.openai.com`. There's no telemetry, analytics or account.

The app is ad-hoc signed when you build it. A locally signed app gets a new signature with each build, so macOS asks once more after each rebuild whether it may read its Keychain item.

## Development

```sh
swift test                                                       # 27 unit tests
./install.sh --build-only                                        # test + build ./build/Voice Note Transcriber.app
swift run -c release transcriber-cli chunks ~/Downloads/note.m4a # where a recording would be split (offline)
swift run -c release transcriber-cli transcribe ~/Downloads/note.m4a --strictness strict --out /tmp/notes
swift run -c release transcriber-cli list ~/Documents/Voice\ Notes   # what the sidebar would list
./scripts/render-screenshots.sh                                  # re-render docs/images (sample data only)
```

`transcriber-cli transcribe` uses the key the app saved in the Keychain, so macOS may ask whether it can read it.

The screenshots come from a debug-only renderer (`SnapshotRenderer.swift`) that draws the real views with made-up notes in light and dark mode. It never reads your Keychain or notes folder.
