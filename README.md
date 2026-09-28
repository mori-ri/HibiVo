# HibiVo

押す → 話す → もう一度押す(または押している間だけ話す)→ 文章が入る。macOS 向けの日本語音声入力アプリです。

- Push-to-Talk（既定は右 Option。Fn / 右 Command / ⌃Space も選べます）
- 話している間にストリーミングで文字起こし（Soniox または Google Gemini）するので、録音を終えたらすぐ入力されます
- LLM で整形（Raw / Natural / Business / Prompt）。アプリごとにモードを自動で切り替えます
- 元のアプリのカーソル位置へ貼り付け、クリップボードは元に戻します
- ユーザー辞書（表記と聞き取り例を登録。聞き取り例は平仮名・片仮名、全角・半角を区別せずに置き換え、STT のヒントにも使います）、履歴（コピー / もう一度入力 / 整形やり直し）
- ミーティングモード: ホットキー + M で録音を続け、マイクとシステム音声（オンライン参加者の声）を話者識別付きで文字起こしして Markdown に保存（Soniox）
- 音声は保存しません。API Key は Keychain に保存します

## 必要なもの

- macOS 14 以降、Apple Silicon
- Command Line Tools（`xcode-select --install`）または Xcode
- 文字起こし用の API Key: [Soniox](https://soniox.com) または [Google AI Studio](https://aistudio.google.com)（Gemini 3.5 Transcribe）
- AI 整形用の LLM（なくても Raw で使えます）: Anthropic API、Amazon Bedrock、Google Gemini API、または OpenAI 互換 API

## インストール（ソースからビルド）

HibiVo は署名済みバイナリを配布していません。自分の Mac でビルドします。
自分でビルドしたアプリには「ダウンロードしたもの」の印が付かないため、Gatekeeper の警告も出ません。

```sh
git clone https://github.com/mori-ri/HibiVo.git
cd HibiVo
scripts/create-signing-cert.sh          # 任意・推奨（下記）
CONFIG=release scripts/build-app.sh      # build/HibiVo.app を作成
mv build/HibiVo.app /Applications/
open /Applications/HibiVo.app
```

`/Applications` に置くと「ログイン時に起動」が使えます。

### 署名証明書（推奨）

`scripts/create-signing-cert.sh` はログインキーチェーンに自己署名のコード署名証明書「HibiVo Self-Signed」を作ります（初回のみ。信頼設定のためにパスワードを求められます）。
以降の `build-app.sh` は自動でこの証明書を使うため、**再ビルドやアップデートのあともアクセシビリティ許可が保たれます**。

証明書がない場合は ad-hoc 署名になり、ビルドのたびにアクセシビリティ許可が外れます。
その場合は `tccutil reset Accessibility io.github.mori-ri.hibivo` を実行して許可し直してください。

### アップデート

```sh
git pull
CONFIG=release scripts/build-app.sh
rm -rf /Applications/HibiVo.app && mv build/HibiVo.app /Applications/
```

## 初回セットアップ

1. 起動するとメニューバーに HibiVo のアイコンが出ます。
2. **アクセシビリティ** を許可します（システム設定 › プライバシーとセキュリティ › アクセシビリティ）。ホットキーと貼り付けに必要です。
3. **マイク** を許可します。
4. メニュー › 設定… › 文字起こし で STT Provider（Soniox / Google Gemini）を選び、API Key を保存します。Gemini の API Key は AI 整形の Google Gemini と共通です。
5. AI 整形 タブで LLM の Provider と認証情報を設定します（既定は Anthropic `claude-opus-5`）。
   Amazon Bedrock の場合はリージョン・モデル ID（または推論プロファイル ID）と、Bedrock API キーか IAM アクセスキー（`bedrock:InvokeModel` 権限）を設定します。
   Claude のほか `zai.glm-4.7-flash`、`zai.glm-4.7`、`minimax.minimax-m2.5`、`global.openai.gpt-6-luna` なども指定できます（設定画面の「候補」から選択可）。
6. 右 Option を押して話し、終わったらもう一度押します(押したまま話して離しても入力できます)。

> **Fn キーを使う場合**: システム設定 › キーボード の「🌐キーを押して」を「何もしない」にしてください。

## 使い方

| 操作 | 動作 |
|---|---|
| ホットキーを押す | 録音開始（HUD にレベルと途中経過を表示） |
| もう一度押す | 録音終了 → 文字起こし確定 → 整形 → 貼り付け |
| 0.4 秒以上押し続けてから離す | 離した時点で録音終了（押している間だけ録音） |
| 0.25 秒未満でもう一度押す / 押し始めに他のキーと同時押し / Esc | キャンセル |
| メニュー › 直前の結果をもう一度入力 | 最後の結果を現在のアプリへ貼り付け |

整形に失敗したときやタイムアウトしたとき（5 秒）は、文字起こし結果をそのまま入力します。

### ミーティングモード

| 操作 | 動作 |
|---|---|
| ホットキーを押しながら M | ミーティングの文字起こしを開始（HUD に赤丸と経過時間） |
| ホットキーをもう一度押して離す | 終了して保存し、Finder でファイルを表示 |
| メニュー › ミーティングの記録を開く… | 保存先フォルダを開く |

- 話者識別付きで文字起こしし、`~/Library/Application Support/HibiVo/Meetings/<開始日時>.md` に数秒ごとに書き足します。途中でアプリが落ちても、それまでの内容は残ります。
- オンライン会議やハイブリッド会議にも対応しています。マイクとシステム音声（Mac で再生中の音 = オンライン参加者の声）を混ぜて 1 本にし、会議室の人もオンラインの人も区別せず `**話者1**`・`**話者2**`… と識別します。
  - システム音声の記録には macOS 14.2 以降と、初回に表示される「システムオーディオ録音」の許可が必要です。画面収録の許可は不要です。設定 › 一般 › ミーティング でオフにできます。
  - スピーカーで聞いていると、相手の声がマイクにも入って少しずれて重なり、認識しにくくなることがあります。イヤホンの使用をおすすめします。
- 貼り付けや AI 整形は行いません。会議中は通常の音声入力は使えません。
- 誤操作で記録を失わないよう、会議中の Esc や、ホットキーと他のキーの同時押し（Fn + ← など）では終了しません。
- STT の設定にかかわらず Soniox を使います（Soniox の API Key が必要）。システム音声を記録しても送る音声は 1 本なので、料金は変わりません。接続が切れたら自動で再接続します。再接続後は話者番号が振り直されます。
- 4 時間で自動的に終了します。

## プライバシー

- **音声**: メモリ上で STT へ送るだけで、ディスクには保存しません。
- **テキスト**: 文字起こしは STT Provider（Soniox / Google Gemini）へ、整形する場合は LLM Provider へ送信されます。各社のデータ取り扱いポリシーに従います。
- **履歴**: 文字起こし原文と整形結果を `~/Library/Application Support/HibiVo/history.json` に平文で最大 200 件保存します。設定 › 一般 › 「履歴を保存する」で無効にでき、履歴画面から全件削除できます。
- **辞書**: `~/Library/Application Support/HibiVo/vocabulary.json` に保存します。
- **ミーティング**: 文字起こしを `~/Library/Application Support/HibiVo/Meetings/` に Markdown で平文保存します。音声は保存しません。
- **API Key / AWS 認証情報**: macOS の Keychain に保存します。設定ファイルには書き込みません。
- 解析・テレメトリの送信はありません。

## 現状と制約（v0.1）

開発者の環境で、Push-to-Talk → 文字起こし → 整形 → 貼り付けの一連の流れを確認済みです。

- STT は Soniox と Google Gemini（`gemini-3.5-transcribe-live`、Live API でストリーミング）
- Amazon Bedrock は Claude（InvokeModel）と、GLM・MiniMax・GPT など Converse API 対応モデルに対応。AWS プロファイル / SSO の認証情報の自動読み込みは未対応
- ホットキーはプリセット（右 Option / Fn / 右 Command / ⌃Space）から選択。任意のキーの登録は未対応
- アプリごとの整形モードは bundle id で判定するため、ブラウザ内の Web アプリ（Gmail など）はブラウザの設定に従う
- パスワード入力中（Secure Input）は貼り付けず、クリップボードにコピーのみ
- 署名済みバイナリは配布していません。ソースからビルドしてください

## フィードバック

「ここが使いにくい」「こうなったら便利」など、小さなことでも歓迎です。

- 💬 [フィードバックを送る](https://github.com/mori-ri/HibiVo/discussions/new?category=feedback) — 良かった点・使いづらかった点
- 💡 [アイデア・要望](https://github.com/mori-ri/HibiVo/discussions/new?category=ideas) — 「こうなったら便利」
- 🙋 [質問・使い方](https://github.com/mori-ri/HibiVo/discussions/new?category=q-a) — ビルドや設定で困ったとき
- 📣 [お知らせ](https://github.com/mori-ri/HibiVo/discussions/categories/announcements) — アップデート情報

アプリのメニュー › 「フィードバック・要望を送る…」からも開けます。
再現手順がはっきりしている不具合は [Issue](https://github.com/mori-ri/HibiVo/issues/new/choose) へどうぞ。

## 開発

```sh
scripts/run.sh        # デバッグビルドして起動
scripts/test.sh       # テスト
```

アイコンを変更したときは `Resources/AppIconSource.png` を差し替えて `swift scripts/make-icons.swift` を実行します。

Xcode プロジェクトはありません。SwiftPM でビルドし、`scripts/build-app.sh` が `.app` を組み立てて署名します。
Command Line Tools だけの環境では、自動的に macOS 26 SDK でビルドします（macOS 27 SDK では SwiftUI の `@State` がマクロになり、そのプラグインが Xcode にしか含まれていないため）。

## ライセンス

ソースコードは [MIT License](LICENSE) です。

アプリアイコンとロゴ（`Resources/AppIconSource.png`、`Resources/AppIcon.icns`、`Resources/MenuBarIcon.png`、`Resources/MenuBarIcon@2x.png`）は MIT License の対象外で、著作権は作者に帰属します。
HibiVo のビルドや紹介のために使うのは構いませんが、fork や派生物を配布するときは別のアイコンに差し替えてください。
