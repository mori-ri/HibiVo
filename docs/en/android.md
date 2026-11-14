English | [日本語](../android.md)

# Android keyboard

An app that lets you use HibiVo as an Android keyboard (IME). Instead of letter keys it has a microphone button, and what you say is entered at the cursor of the app you are typing in. The source is in `android/`.

There is no release build yet. Build and install it yourself.

## What it does

- Tap the microphone, speak, and tap again to enter the text. You can also hold it while you speak and let go (when held for 0.4 seconds or longer).
- Transcription is either **Android built-in** (the device's speech recognition; no API key) or **Soniox** (streams while you speak; needs an API key).
- AI cleanup (Raw / Natural / Business / Prompt / Custom) uses the same prompts as the macOS app. Providers: Anthropic, OpenAI compatible, and Google Gemini. Tap the mode name at the top left to change the mode.
- The dictionary (spellings and how they are misheard) follows the same rules as the macOS app, and is also used as a hint for transcription and cleanup.
- The keyboard key at the bottom left switches to the regular keyboard you used before (long-press for the list of keyboards). Make fine corrections there, and come back with that keyboard's own switch key.
- Keys for comma, period, space, cursor movement, delete and enter, plus a button that undoes the last dictation.
- When cleanup fails or times out, the transcript is entered as it is.
- Dictation is off in password fields.
- Audio is never stored. API keys are encrypted with a key in the Android Keystore, kept on the device, and excluded from backups.

In the macOS app but not here: meeting mode, history, usage, learning dictionary words from corrections, per-app modes, Gemini transcription, and Amazon Bedrock.

## Build and install

You need JDK 17 or later and the Android SDK (API 35). Open `android/` in Android Studio, or run:

```sh
cd android
./gradlew :app:assembleDebug                 # app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug   # tests and lint
```

It runs on Android 9 (API 28) and later.

## First-time setup

1. Open the HibiVo app and use "Turn on the HibiVo keyboard" to enable HibiVo in the system settings.
2. Tap "Allow the microphone" and allow it.
3. Tap "Try it here" at the top, switch the keyboard to HibiVo, and speak.
4. To use Soniox, choose it under "Speech recognition" and save your API key.
5. To use AI cleanup, choose a provider and save its API key (until then, text is entered as spoken).

## Layout

- `android/core`: a Kotlin module with no Android dependency. Cleanup prompts and output checks, dictionary replacement, the Soniox session, and the cleanup providers. The prompts and dictionary rules are the same as the macOS app's (`Sources/HibiVoKit/Cleanup`, `Vocabulary`), so change both together.
- `android/app`: the keyboard (`HibiVoInputMethodService`), recording and recognition (`Recognizer.kt`), dictation state (`DictationController`), and the settings and dictionary screens.

The app icon is taken from `Resources/AppIconSource.png` at build time.
