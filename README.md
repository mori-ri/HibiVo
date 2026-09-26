# HibiVo

押す → 話す → 離す → 文章が入る。macOS 向けの日本語音声入力アプリです。

- Push-to-Talk（既定は右 Option。Fn / 右 Command / ⌃Space も選べます）
- 話している間にストリーミングで文字起こし（Soniox）するので、キーを離したらすぐ入力されます
- LLM で整形（Raw / Natural / Business / Prompt）。アプリごとにモードを自動で切り替えます
- 元のアプリのカーソル位置へ貼り付け、クリップボードは元に戻します
- ユーザー辞書、履歴（コピー / もう一度入力 / 整形やり直し）
- 音声は保存しません。API Key は Keychain に保存します

## 必要なもの

- macOS 14 以降、Apple Silicon
- Command Line Tools（`xcode-select --install`）または Xcode
- [Soniox](https://soniox.com) の API Key（文字起こし）
- AI 整形用の LLM（なくても Raw で使えます）: Anthropic API、Amazon Bedrock、または OpenAI 互換 API

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
4. メニュー › 設定… › 文字起こし で Soniox の API Key を保存します。
5. AI 整形 タブで LLM の Provider と認証情報を設定します（既定は Anthropic `claude-opus-5`）。
   Amazon Bedrock の場合はリージョン・モデル ID（または推論プロファイル ID）と、Bedrock API キーか IAM アクセスキー（`bedrock:InvokeModel` 権限）を設定します。
   Claude のほか `zai.glm-4.7-flash`、`zai.glm-4.7`、`minimax.minimax-m2.5`、`global.openai.gpt-6-luna` なども指定できます（設定画面の「候補」から選択可）。
6. 右 Option を押しながら話し、離します。

> **Fn キーを使う場合**: システム設定 › キーボード の「🌐キーを押して」を「何もしない」にしてください。

## ビルド済みアプリを共有する

```sh
scripts/package.sh    # build/HibiVo-<version>-arm64.zip を作成
```

- zip は `ditto` で作るため、署名が壊れません。
- 共有する側は `create-signing-cert.sh` の証明書で署名しておくと、相手もアップデート後に許可をやり直さずに済みます（**毎回同じ証明書で署名すること**）。
- 公証（notarization）していないため、受け取った側では初回に Gatekeeper に止められます。どちらかの方法で開きます。
  - 一度起動を試してから、システム設定 › プライバシーとセキュリティ の「このまま開く」を押す
  - または `xattr -dr com.apple.quarantine /Applications/HibiVo.app` を実行する
- Apple Silicon 専用です。API Key は各自で設定します。

## 使い方

| 操作 | 動作 |
|---|---|
| ホットキーを押し続ける | 録音（HUD にレベルと途中経過を表示） |
| 離す | 文字起こし確定 → 整形 → 貼り付け |
| 0.25 秒未満で離す / 押している間に他のキー / Esc | キャンセル |
| メニュー › 直前の結果をもう一度入力 | 最後の結果を現在のアプリへ貼り付け |

整形に失敗したときやタイムアウトしたとき（5 秒）は、文字起こし結果をそのまま入力します。

## プライバシー

- **音声**: メモリ上で STT へ送るだけで、ディスクには保存しません。
- **テキスト**: 文字起こしは STT Provider（Soniox）へ、整形する場合は LLM Provider へ送信されます。各社のデータ取り扱いポリシーに従います。
- **履歴**: 文字起こし原文と整形結果を `~/Library/Application Support/HibiVo/history.json` に平文で最大 200 件保存します。設定 › 一般 › 「履歴を保存する」で無効にでき、履歴画面から全件削除できます。
- **辞書**: `~/Library/Application Support/HibiVo/vocabulary.json` に保存します。
- **API Key / AWS 認証情報**: macOS の Keychain に保存します。設定ファイルには書き込みません。
- 解析・テレメトリの送信はありません。

## 現状と制約（v0.1）

開発者の環境で、Push-to-Talk → 文字起こし → 整形 → 貼り付けの一連の流れを確認済みです。

- STT は Soniox のみ（Provider は差し替え可能な設計）
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
