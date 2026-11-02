English | [日本語](README.md)

<p align="center">
  <img src="Resources/AppIconSource.png" alt="HibiVo" width="200">
</p>

# HibiVo

Press → speak → press again (or hold while you speak) → your text appears. A voice input app for macOS, built Japanese-first. Try how it works on the [website](https://mori-ri.github.io/HibiVo/en/).

> **About languages**: HibiVo is designed for Japanese first.
> - The UI is available in Japanese and English and follows your macOS language by default. You can also choose it in Settings › General › App Language.
> - To dictate in English, set Settings… › Transcription › Language to English. AI Cleanup and meeting minutes then use English prompts too, so text is cleaned up and minutes are written in English.

- Push-to-Talk (right Option by default; Fn / right Command / ⌃Space are also available)
- Transcribes while you speak, so your text is entered right after you stop recording. The default is macOS's built-in transcription (macOS 26 or later; runs on your Mac, no API key, free). Soniox or Google Gemini can also be chosen
- Cleans up text with an LLM (Raw / Natural / Business / Prompt / Custom), switching modes automatically per app
- Pastes at the cursor in the original app, then restores your clipboard
- Dictionary (register a spelling and how it sounds; "sounds like" forms are matched regardless of hiragana/katakana and full-/half-width, and are also used as hints for speech recognition), History (copy / insert again / redo cleanup)
- Meeting mode: hotkey + M keeps recording, transcribes the microphone and system audio (the voices of remote participants) and saves the transcript as Markdown (macOS (On-Device) by default; Soniox adds speaker identification)
- Audio is not saved (except temporarily, until transcription finishes, when a meeting is transcribed After the Meeting). API keys are stored in the Keychain

## Requirements

- macOS 14 or later, Apple Silicon
- Transcription: on macOS 26 or later, macOS (On-Device) transcription works without an API key. Otherwise, or if you want speaker identification or cloud recognition, an API key from [Soniox](https://soniox.com) or [Google AI Studio](https://aistudio.google.com) (Gemini 3.5 Transcribe)
- An LLM for AI Cleanup (optional; you can use Raw without one): Anthropic API, Amazon Bedrock, Google Gemini API, or an OpenAI-compatible API

## Installation

Download `HibiVo-<version>-arm64.zip` from [Releases](https://github.com/mori-ri/HibiVo/releases/latest), unzip it, move `HibiVo.app` to `/Applications` and open it. The app is signed with Developer ID and notarized by Apple.

The app tells you when a new version is out. Nothing is installed automatically (you can turn this off in Settings › General).

To build it yourself, see [Build from source](docs/en/building.md).

## First-time setup

1. When launched, the HibiVo icon appears in the menu bar.
2. Allow **Accessibility** (System Settings › Privacy & Security › Accessibility). It is needed for the hotkey and for pasting.
3. Allow the **Microphone**.
4. In the menu › Settings… › Transcription, choose the STT Provider. The default, "macOS (On-Device)", needs no setup (the speech model is downloaded automatically the first time). To use Soniox / Google Gemini, save an API key. The Gemini API key is shared with Google Gemini in AI Cleanup.
5. In the AI Cleanup tab, set the LLM provider and its credentials (the default is Anthropic `claude-haiku-4-5`; cleaning up short text favors response speed, so each provider's default is a lightweight model).
   For Amazon Bedrock, set the region, the model ID (or inference profile ID), and either a Bedrock API key or IAM access keys (with the `bedrock:InvokeModel` permission).
   Besides Claude you can specify `zai.glm-4.7-flash`, `zai.glm-4.7`, `minimax.minimax-m2.5`, `global.openai.gpt-6-luna` and others (selectable from "Suggestions" in Settings).
6. Press right Option, speak, and press it again when you are done (you can also hold it while you speak and release it).

> **Using the Fn key**: set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing".

## Usage

| Action | Result |
|---|---|
| Press the hotkey | Start recording (the HUD shows the level and the live transcript) |
| Press it again | Stop recording → finalize transcription → clean up → paste |
| Hold for 0.4 s or longer, then release | Recording stops on release (records only while held) |
| Press again within 0.25 s / press with another key at the start / Esc | Cancel |
| Menu › Paste Last Result Again | Paste the last result into the current app |

If cleanup fails or times out (5 s, extended by 1 s per 50 characters for long text, up to 30 s), the raw transcript is entered as is.

For the differences between the cleanup modes (Raw / Natural / Business / Prompt / Custom) with sample output, see [AI Cleanup modes](docs/en/cleanup-modes.md).

Register company names and technical terms in the Dictionary so they are entered correctly. If you fix a misrecognized word right after it is entered, that word is added to the Dictionary automatically. See [Dictionary](docs/en/dictionary.md) for details.

### Meeting mode

| Action | Result |
|---|---|
| Hold the hotkey and press M | Start transcribing a meeting (the HUD shows a red dot and the elapsed time) |
| Press the hotkey twice quickly (or hold the hotkey and press M) | Stop, save, and show the file in Finder |
| Settings › Meeting › Save location "Open…" | Open the save folder |

- The transcript is saved to `~/Library/Application Support/HibiVo/Meetings/<start date and time>.md`.
- Transcription is chosen in Settings › Meeting (separately from the STT for dictation).
  - **macOS (On-Device)** (the default on macOS 26 or later): transcribes on your Mac. No API key and no charges. Speakers are not distinguished. Always transcribes in Real Time. A meeting cannot start until the speech model is ready (downloaded the first time).
  - **Soniox**: identifies speakers and labels them `**話者1**` (Speaker 1), `**話者2**` (Speaker 2), and so on. Requires a Soniox API key.
- With Soniox you can choose when to transcribe.
  - **Real Time** (default): transcribes during the meeting and appends to the file every few seconds. If the app quits unexpectedly, everything up to that point is kept. Speaker separation is somewhat coarse; different people may be merged into the same speaker.
  - **After the Meeting**: only records during the meeting and transcribes the whole recording afterwards, so speakers are separated accurately. It is also slightly cheaper than Real Time. Results for a one-hour meeting arrive within a few minutes, and the file is then shown in Finder. You can keep dictating or start the next meeting while it transcribes. The recorded audio is kept temporarily on your Mac until transcription finishes (readable only by you and excluded from Time Machine backups). If your Mac shuts down, sleeps, or loses the network midway, transcription continues the next time the app launches, the Mac wakes, or the network comes back. If the audio was already sent to Soniox, only the result is fetched, without sending it again. The temporary audio is deleted when transcription finishes, and also if it still cannot be transcribed after 7 days.
- Online and hybrid meetings are supported. The microphone and system audio (sound played on the Mac = the voices of online participants) are mixed into one stream, so people in the room and online are treated alike, and Soniox labels them `**話者1**`, `**話者2**`, ….
  - Recording system audio requires macOS 14.2 or later and the "System Audio Recording" permission shown the first time. Screen Recording permission is not needed. You can turn it off in Settings › Meeting.
  - If you listen through speakers, the other side's voices also reach the microphone slightly delayed and overlap, which can make recognition harder. Earphones are recommended.
- If the microphone changes during recording, recording resumes automatically. If the selected microphone is disconnected, the system default microphone is used (the setting is not changed). Microphone audio cannot be recorded while switching. If recording cannot resume, the meeting ends, a note is left in the transcript, and an error is shown.
- When the Mac sleeps, the meeting ends and is saved at that point. Transcription and minutes are done after the Mac wakes. When the app quits or the Mac shuts down, the meeting is ended first.
- No pasting or AI Cleanup. Normal dictation is unavailable during a meeting.
- To avoid losing a recording by mistake, a single press of the hotkey, a long press, Esc during the meeting, or pressing the hotkey together with another key (Fn + ←, Fn + volume keys, and so on) does not end the meeting.
- With Soniox, recording system audio still sends a single stream, so the cost does not change. If the connection drops, it reconnects automatically. Speaker numbers restart after reconnecting.
- Meetings end automatically after 4 hours.
- **Minutes** (off by default): turn them on in Settings › Meeting to get minutes from the transcript after the meeting (summary, decisions, to-dos, discussion, open issues), saved next to it as `<start date and time>_<title describing the meeting>.md` (for example `2026-09-27_14-00-05_新機能リリース計画.md`). The title comes from the content. Your Dictionary is passed along too, so registered spellings are used in the minutes.
  - Under Settings › Meeting › "Written With" choose an AI Cleanup provider (Anthropic, OpenAI-compatible, Amazon Bedrock, or Google Gemini) with the same credentials. API charges apply, and the cost appears in Usage.
  - You can also choose a separately installed [Claude Code](https://claude.com/claude-code). HibiVo only runs it and never reads or writes its credentials. Sign-in and terms follow your Claude Code setup, and its usage is not counted in HibiVo's Usage. The model (Opus / Sonnet / Haiku; Sonnet by default) and the location of the executable can be changed in Settings › Meeting.
  - Claude Code runs in an empty temporary folder with all tools, MCP, and settings files disabled. It does nothing but read the transcript and return the minutes.
- **Recording consent**: some countries, regions, and organizations require participants' consent to record or transcribe. Tell participants, and follow the applicable laws and your organization's rules. Complying with them is your responsibility.

## Privacy

- **Audio**: only sent from memory to the STT; not written to disk. The exception is a meeting transcribed After the Meeting: its audio stays on your Mac until the transcript is done (and is deleted after 7 days if it can't be). With macOS (On-Device) transcription, audio never leaves your Mac.
- **Text**: if you choose Soniox / Google Gemini, audio is sent to that STT provider, and when cleaning up, text is sent to the LLM provider. Each company's data handling policy applies.
- **History**: raw transcripts and cleaned-up results are saved in plain text to `~/Library/Application Support/HibiVo/history.json`, up to 200 entries. You can turn this off with "Save History" at the top right of the History screen, and delete everything from the same screen.
- **Dictionary**: saved to `~/Library/Application Support/HibiVo/vocabulary.json`.
- **Meetings**: transcripts and minutes are saved as plain-text Markdown in `~/Library/Application Support/HibiVo/Meetings/`. When writing minutes, the transcript is sent to Anthropic through Claude Code, or to the provider chosen in "Written With".
- **API keys / AWS credentials**: stored in the macOS Keychain, never in settings files.
  - API keys for Soniox, Gemini, Anthropic, OpenAI-compatible, and Bedrock are stored together in a single HibiVo item. Access permission to that item applies to all saved API keys.
  - Retrieved API keys are kept in the app's memory, so normal use does not retrieve or re-approve each key. If you change a key from outside (for example in Keychain Access), restart HibiVo.
  - AWS IAM access key ID, secret access key, and session token stay stored separately, because the app cannot tell the scope of their permissions.
  - Existing API keys are migrated the first time they are retrieved or saved. Migration may ask for approval for each old item. Old items are deleted only after the combined item is saved successfully. Keys you deny access to are not migrated and are asked about again on the next launch (saving that key again in Settings deletes the old item). If deleting an old item fails, it remains, but the combined item is used from then on.
  - Allowing the eval CLI (`HibiVoEval`) to access the combined item lets it retrieve all saved API keys. Re-approval after signature changes and similar events may still happen after the keys are combined.
- **Update check**: at launch and once a day, HibiVo asks GitHub for the latest version. This is an ordinary HTTPS request, so GitHub sees your IP address and similar connection details. You can turn it off in Settings › General.
- No analytics or telemetry are sent.

### Permissions HibiVo asks for

- **Accessibility**: detecting the hotkey, pasting (sending ⌘V), and learning from your corrections (reading the text field right after a paste). What you type and the text in fields are neither saved nor sent.
- **Microphone**: dictation and meeting recording, only while recording.
- **System Audio Recording**: recording remote participants in meetings, only during a meeting.

## Status and limitations

The full flow Push-to-Talk → transcription → cleanup → paste has been verified in the developer's environment.

- STT: macOS (On-Device) (`SpeechAnalyzer`, macOS 26 or later), Soniox, Google Gemini (`gemini-3.5-transcribe-live`, streamed over the Live API)
- Amazon Bedrock supports Claude (InvokeModel) and Converse API models such as GLM, MiniMax, and GPT. Loading credentials automatically from AWS profiles / SSO is not supported
- The hotkey is chosen from presets (right Option / Fn / right Command / ⌃Space). Registering an arbitrary key is not supported
- Per-app cleanup modes are matched by bundle ID, so web apps in a browser (Gmail and so on) follow the browser's setting
- During password entry (Secure Input), text is only copied to the clipboard, not pasted
- The distributed app is for Apple Silicon. On Intel Macs, please [build from source](docs/en/building.md)

## Feedback

Anything is welcome, however small: "this is hard to use", "it would be nice if…".

- 💬 [Send feedback](https://github.com/mori-ri/HibiVo/discussions/new?category=feedback) — what worked well and what didn't
- 💡 [Ideas and requests](https://github.com/mori-ri/HibiVo/discussions/new?category=ideas) — "it would be nice if…"
- 🙋 [Questions and how-to](https://github.com/mori-ri/HibiVo/discussions/new?category=q-a) — when you are stuck building or setting up
- 📣 [Announcements](https://github.com/mori-ri/HibiVo/discussions/categories/announcements) — update news

You can also open these from the app's menu › "Send Feedback or Requests…".
For bugs with clear steps to reproduce, please open an [Issue](https://github.com/mori-ri/HibiVo/issues/new/choose).

## Development

For building and working on HibiVo, see [Build from source](docs/en/building.md).

## License

The source code is under the [MIT License](LICENSE).

The app icon and logo (`Resources/AppIconSource.png`, `Resources/AppIcon.icns`, `Resources/MenuBarIcon.png`, `Resources/MenuBarIcon@2x.png`, `Resources/Logo.png`, `Resources/Logo@2x.png`, `site/assets/`) are not covered by the MIT License; their copyright belongs to the author.
You may use them to build or introduce HibiVo, but please replace them with a different icon when distributing forks or derivative works.
