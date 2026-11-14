English | [日本語](../ios.md)

# iPhone (Keyboard)

On iPhone, HibiVo is a keyboard. In any app, switch the keyboard to HibiVo, tap the microphone and speak; the text goes in at the cursor.

> This is still in development and isn't distributed. To use it, build it with Xcode on your Mac and install it on your iPhone. It has not been tested on a device yet.

## How to Use It

1. Wherever you type, tap 🌐 and switch the keyboard to HibiVo.
2. Tap the microphone. If the microphone is off, the HibiVo app opens and turns it on. Go back to the app you were in with “◀” at the top left, or by swiping right along the bottom edge.
3. Tap the microphone again and speak, then tap stop. The text goes in at the cursor.

The microphone turns off by itself after a while without use (5 minutes by default; you can change this in Settings). While it is on, the microphone indicator shows at the top of the screen.

## Differences from the Mac App

- **The keyboard's microphone replaces the hotkey.** iOS doesn't let an app watch keys over other apps.
- **The app does the recording.** iOS doesn't let keyboards use the microphone. So the app waits in the background with the microphone on and starts transcribing when the keyboard tells it to.
- **There are no per-app cleanup modes.** iOS doesn't tell a keyboard which app it is typing into. You pick one mode in Settings.
- **There is no meeting mode, no learning from corrections and no usage page.**
- Transcription (iPhone on-device, Soniox, Google Gemini), AI cleanup (Anthropic, OpenAI-compatible, Amazon Bedrock, Google Gemini), the dictionary and the history work the same way as on the Mac. Bedrock takes an API key only.
- Settings, the dictionary, the history and API keys don't sync with the Mac app.

## Privacy

- Audio is never stored. It is only transcribed between tapping the microphone on the keyboard and stopping.
- The on-device transcription stays on the iPhone. With Soniox, Gemini or AI cleanup, audio or text is sent to the service you chose.
- The keyboard needs Full Access, to use the folder it shares with the app. The keyboard itself doesn't read what is in the text field and never connects to the network.
- The transcript is written to the shared folder briefly so the keyboard can pick it up, and removed when the next dictation starts or the microphone is turned off.

## Building

You need Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), an iPhone on iOS 26 or later, and an Apple Developer team (for the App Group).

```sh
cp iOS/Config/Signing.xcconfig.example iOS/Config/Signing.xcconfig   # put your team ID in it
scripts/ios-project.sh                                                # creates iOS/HibiVo.xcodeproj
open iOS/HibiVo.xcodeproj
```

In Xcode, pick the HibiVo scheme, connect your iPhone and run. Then follow the steps on the app's Home screen to add the keyboard and allow Full Access.

The bundle ID (`io.github.mori-ri.hibivo.ios`) and the App Group (`group.io.github.mori-ri.hibivo.ios`) can't be registered by another team. To build with your own team, change them to your own IDs in `iOS/project.yml`, the two `.entitlements` files and `appGroup` in `iOS/Core/Bridge/KeyboardBridge.swift`.

The Xcode project is generated from `iOS/project.yml` and is not committed. Run `scripts/ios-project.sh` again after adding files or changing `project.yml`.

## How It Works

```
Keyboard extension ── commands (file + Darwin notification) ──▶ App (in the background)
      ▲                                                         │ microphone → transcription → dictionary → AI cleanup
      └────────── state and result (file + Darwin notification) ◀┘
```

- `iOS/Core/`: how the keyboard and the app talk (`KeyboardBridge`) and the keyboard's state (`KeyboardModel`). Written with Foundation only, so `scripts/test.sh` tests it on a Mac.
- `iOS/Keyboard/`: the keyboard extension. It only sends commands and enters the result with `textDocumentProxy.insertText`.
- `iOS/App/`: the app. The microphone (`MicrophoneSession`), the dictation flow (`MobileDictationController`) and the screens.
- Transcription, AI cleanup, the dictionary and the history are the Mac app's sources (`Sources/HibiVoKit/`), compiled as they are where a file has nothing Mac-only in it. `iOS/project.yml` lists them.

iOS has no official way for a keyboard to open its app. HibiVo uses the widely used approach of finding the host app's `UIApplication` through the responder chain and opening a URL with it. An iOS update could stop this from working. If it does, you can still open the app first and turn the microphone on there.
