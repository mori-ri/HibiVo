[English](en/android.md) | 日本語

# Android キーボード

HibiVo を Android のキーボード(IME)として使うためのアプリです。文字のキーの代わりにマイクのボタンがあり、話した内容が入力中のアプリのカーソル位置に入ります。ソースは `android/` にあります。

配布用のビルドはまだありません。自分でビルドしてインストールしてください。

## できること

- マイクをタップして話し、もう一度タップすると入力されます。押したまま話して離しても入力できます(0.4 秒以上押した場合)。
- 文字起こしは **Android 標準**(端末の音声認識。API Key 不要)か **Soniox**(話している間にストリーミングで文字起こし。API Key が必要)を選べます。
- AI 整形(Raw / Natural / Business / Prompt / Custom)は macOS 版と同じプロンプトです。プロバイダは Anthropic、OpenAI 互換、Google Gemini から選べます。左上のモード名をタップすると切り替わります。
- 辞書(表記と聞き取り例)は macOS 版と同じ規則で置き換え、文字起こしと整形のヒントにも使います。
- 左下のキーボードのキーで、直前に使っていた通常のキーボードに切り替わります(長押しでキーボードの一覧)。細かい修正は通常のキーボードで行い、そのキーボードの切り替えキーで HibiVo に戻れます。
- 「、」「。」・空白・カーソル移動・削除・改行のキーと、直前の音声入力を取り消すボタンがあります。
- 整形に失敗したときやタイムアウトしたときは、文字起こしの結果をそのまま入力します。
- パスワードの入力欄では音声入力を使えません。
- 音声は保存しません。API Key は Android Keystore の鍵で暗号化して端末内に保存し、バックアップの対象にしません。

macOS 版にあってこのアプリにないもの: ミーティングモード、履歴、利用状況、修正からの辞書の自動学習、アプリ別のモード、Gemini の文字起こし、Amazon Bedrock。

## ビルドとインストール

JDK 17 以降と Android SDK(API 35)が必要です。Android Studio で `android/` を開くか、次のように実行します。

```sh
cd android
./gradlew :app:assembleDebug                 # app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
./gradlew :core:test :app:testDebugUnitTest :app:lintDebug   # テストと lint
```

Android 9(API 28)以降で動きます。

## 初回セットアップ

1. HibiVo アプリを開き、「HibiVo キーボードを有効にする」からシステムの設定で HibiVo をオンにします。
2. 「マイクを許可する」をタップして許可します。
3. 画面上部の「ここで試す」をタップし、キーボードを HibiVo に切り替えて話します。
4. Soniox を使う場合は「音声認識」で Soniox を選び、API Key を保存します。
5. AI 整形を使う場合は、プロバイダを選んで API Key を保存します(未設定の間は、話したままの文章が入ります)。

## 構成

- `android/core`: Android に依存しない Kotlin のモジュール。整形のプロンプトと出力の検査、辞書の置き換え、Soniox のセッション、整形プロバイダ。プロンプトと辞書の規則は macOS 版(`Sources/HibiVoKit/Cleanup`、`Vocabulary`)と同じ内容なので、変更するときは両方を直してください。
- `android/app`: キーボード(`HibiVoInputMethodService`)、録音と認識(`Recognizer.kt`)、音声入力の状態管理(`DictationController`)、設定と辞書の画面。

アプリのアイコンは、ビルド時に `Resources/AppIconSource.png` から取り込みます。
