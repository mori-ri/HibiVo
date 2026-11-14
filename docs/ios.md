[English](en/ios.md) | 日本語

# iPhone 版（キーボード）

iPhone では、HibiVo をキーボードとして使います。どのアプリでも、キーボードを HibiVo に切り替えてマイクを押し、話すと、文章がカーソルの位置に入ります。

> まだ開発中で、配布はしていません。使うには、自分の Mac で Xcode からビルドして iPhone に入れます。実機での動作確認はこれからです。

## 使い方

1. 文字を入力する画面で 🌐 を押し、キーボードを HibiVo に切り替えます。
2. マイクを押します。マイクがオフなら HibiVo のアプリが開き、マイクがオンになります。画面左上の「◀」か、画面の下端を右にスワイプして、元のアプリに戻ります。
3. もう一度マイクを押して話し、終わったら停止を押します。文章がカーソルの位置に入ります。

マイクはしばらく使わないと自動でオフになります（既定は 5 分。設定で変えられます）。オンの間は、画面の上にマイクの印が出ます。

## Mac 版との違い

- **ホットキーの代わりにキーボードのマイクを使います。** iOS では、ほかのアプリの上でキーを監視できないためです。
- **録音はアプリが行います。** iOS はキーボードにマイクを使わせません。そのため、アプリがバックグラウンドでマイクをオンにしたまま待ち、キーボードからの合図で文字起こしを始めます。
- **アプリごとの整形モードはありません。** iOS は、キーボードにどのアプリで入力しているかを教えません。モードは設定で 1 つ選びます。
- **ミーティングモード、修正からの辞書学習、利用状況はありません。**
- 文字起こし（iPhone 標準・Soniox・Google Gemini）、AI 整形（Anthropic・OpenAI 互換・Amazon Bedrock・Google Gemini）、辞書、履歴は Mac 版と同じ仕組みです。Bedrock は API キーだけに対応しています。
- 設定、辞書、履歴、API Key は Mac 版と同期しません。

## プライバシー

- 音声は保存しません。文字起こしに使うのは、キーボードのマイクを押してから止めるまでの間だけです。
- 「iPhone 標準」の文字起こしは iPhone の中で処理します。Soniox や Gemini、AI 整形を使うときは、選んだサービスに音声や文章を送ります。
- キーボードは「フルアクセス」を必要とします。アプリとやり取りするための共有フォルダを使うためです。キーボード自身は入力欄の内容を読み取らず、ネットワークにも接続しません。
- 文字起こしの結果は、キーボードに渡すために共有フォルダへ一時的に書き、次の音声入力を始めたときかマイクをオフにしたときに消します。

## ビルド

必要なもの: Xcode 26 以降、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）、iOS 26 以降の iPhone、Apple Developer のチーム（App Group を使うため）。

```sh
cp iOS/Config/Signing.xcconfig.example iOS/Config/Signing.xcconfig   # チーム ID を書く
scripts/ios-project.sh                                                # iOS/HibiVo.xcodeproj を作る
open iOS/HibiVo.xcodeproj
```

Xcode で HibiVo スキームを選び、iPhone を接続して実行します。そのあと、アプリのホームに出る手順でキーボードを追加し、フルアクセスを許可してください。

バンドル ID（`io.github.mori-ri.hibivo.ios`）と App Group（`group.io.github.mori-ri.hibivo.ios`）は、ほかのチームでは登録できません。自分のチームでビルドするときは、`iOS/project.yml`、2 つの `.entitlements`、`iOS/Core/Bridge/KeyboardBridge.swift` の `appGroup` を自分の ID に書き換えてください。

Xcode プロジェクトは `iOS/project.yml` から作るもので、コミットしません。ファイルを追加したり `project.yml` を変えたりしたら、`scripts/ios-project.sh` をもう一度実行します。

## しくみ

```
キーボード拡張 ── コマンド(ファイル + Darwin 通知) ──▶ アプリ(バックグラウンド)
      ▲                                                  │ マイク → 文字起こし → 辞書 → AI 整形
      └────────── 状態と結果(ファイル + Darwin 通知) ◀──┘
```

- `iOS/Core/`: キーボードとアプリのやり取り（`KeyboardBridge`）と、キーボードの状態の管理（`KeyboardModel`）。Foundation だけで書いてあり、`scripts/test.sh` が Mac でテストします。
- `iOS/Keyboard/`: キーボード拡張。コマンドを送り、結果を `textDocumentProxy.insertText` で入力するだけです。
- `iOS/App/`: アプリ。マイク（`MicrophoneSession`）、音声入力の流れ（`MobileDictationController`）、画面。
- 文字起こし、AI 整形、辞書、履歴は、Mac 版のソース（`Sources/HibiVoKit/`）のうち Mac 専用の部分がないファイルをそのままコンパイルします。対象は `iOS/project.yml` に並べています。

キーボードからアプリを開く公式な方法は iOS にありません。HibiVo は、レスポンダチェーンからホストアプリの `UIApplication` を探して URL を開く、広く使われている方法を使っています。iOS の更新で動かなくなる可能性があります。その場合も、先にアプリを開いてマイクをオンにしておけば使えます。
