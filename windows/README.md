# HibiVo for Windows（開発中）

macOS 版 HibiVo の Windows 版です。Tauri 2（Rust + React / TypeScript）で作っています。
いまは**音声入力の最小構成**だけです。ホットキーを押して話し、もう一度押すと、Soniox で文字起こしし、（設定していれば）AI で整形して、カーソルの位置に貼り付けます。

## できること・まだできないこと

| 機能 | 状態 |
|---|---|
| ホットキー（右 Ctrl・変換・無変換）。短く押すと次に押すまで録音し、長押しすると離したときに止める。Esc で取り消し | ✅ |
| Soniox（`stt-rt-v5`）でのリアルタイム文字起こし | ✅ |
| AI 整形（Anthropic・OpenAI 互換・Gemini、Raw / Natural / Business / Prompt / Custom） | ✅ macOS 版と同じプロンプト |
| クリップボード + Ctrl+V での貼り付け（元のクリップボードは戻す。Win+V の履歴には残さない） | ✅ |
| 録音中・処理中の HUD、タスクトレイ常駐、API Key は資格情報マネージャーに保存 | ✅ |
| 辞書、修正からの辞書学習、アプリ別モード、履歴の保存、利用状況 | まだ |
| ミーティングモード、議事録 | まだ |
| macOS 標準のような端末内の音声認識、Gemini の文字起こし、Bedrock | まだ |
| 英語の UI、ログイン時の自動起動、マイクの選択 | まだ |

## 必要なもの

- Windows 10 / 11（x64）。WebView2 ランタイム（Windows 11 には標準で入っています）
- [Soniox](https://soniox.com/) の API Key
- AI 整形を使うなら、Anthropic・OpenAI 互換・Gemini のいずれかの API Key

## インストール

GitHub Actions の「Windows」ワークフローの実行結果から、成果物 `HibiVo-windows-installer` をダウンロードして実行します。
コード署名をしていないため、SmartScreen の警告が出ます（「詳細情報」→「実行」）。

## 使い方

1. 初回は設定画面が開きます。Soniox の API Key を保存します。AI 整形を使う場合は、プロバイダとその API Key も保存します。
2. 入力したいアプリのテキスト欄にカーソルを置き、**右 Ctrl** を押して話し、もう一度押します。
3. HibiVo はタスクトレイに常駐します。設定画面はトレイのアイコンから開けます。閉じても終了しません。

- 管理者として実行中のアプリには、Windows の制限で貼り付けられません。その場合はクリップボードにコピーだけします。
- マイクを使えないときは、Windows の［設定］›［プライバシーとセキュリティ］›［マイク］で「デスクトップ アプリがマイクにアクセスできるようにする」をオンにしてください。

## 開発

Windows 上で開発します（Rust、Node.js 22、[Tauri の前提条件](https://tauri.app/start/prerequisites/)）。

```powershell
cd windows
npm ci
npm run icons          # ../Resources/AppIconSource.png からアイコンを生成（初回とアイコン変更時）
npm run tauri dev      # 開発版を起動
npm test               # TypeScript のテスト (Vitest)
npm run typecheck
npm run tauri build -- --bundles nsis   # インストーラーを作る
```

Rust の判定ロジックのテストは OS を問わず動きます。

```sh
cd windows/src-tauri && cargo test -p hibivo-core
```

### 構成

```
windows/
  src/core/         OS に依存しないロジック（macOS 版の移植。Vitest でテスト）
    cleanup/        整形のプロンプト、出力のチェック、タイムアウト付きの実行、各プロバイダ
    transcription/  Soniox のリアルタイム文字起こし
    dictation/      音声入力の状態遷移（録音 → 文字起こし → 整形 → 貼り付け）
  src/platform/     Rust 側（コマンド・イベント・Tauri プラグイン）とのつなぎ
  src/settings/     設定画面（React）と、アプリ全体を組み立てる AppRuntime
  src/hud/          HUD（React）
  src-tauri/        Rust。OS が持つものだけを担当する
    core/           OS に依存しない部分（ホットキーの判定、リサンプリング）
    src/hotkey.rs   低レベルキーボードフック
    src/audio.rs    マイク（cpal / WASAPI）→ 16 kHz モノラル PCM16
    src/paste.rs    クリップボードの退避・復元と Ctrl+V
    src/secrets.rs  資格情報マネージャー
    src/hud.rs      フォーカスを奪わない HUD ウィンドウ
```

- 音声入力の処理は TypeScript で、隠れたメインウィンドウの中で動きます。WebView2 が隠れたページを止めないよう、ブラウザの引数でタイマーの抑制を切り、Web Lock を持ち続けています。
- Rust は OS が持つものだけを受け持ちます。キーを横取りするかどうかはフックの中で即座に決める必要があるため、ホットキーの判定（`hibivo-core::hotkey`）は Rust にあります。
- 整形のリクエストは Rust（tauri-plugin-http）経由で送り、Origin ヘッダを付けません。CORS の制約を受けず、サーバー側からの呼び出しとして扱われます。
- `src/core` は macOS 版（`Sources/HibiVoKit`）の移植です。プロンプトの文言は macOS 版と同じに保ってください（評価の結果をそのまま使うため）。どちらかを変えたら、もう一方も合わせます。
- アイコン（`src-tauri/icons/`）は生成物でコミットしません。ロゴは MIT License の対象外です（リポジトリの README を参照）。
