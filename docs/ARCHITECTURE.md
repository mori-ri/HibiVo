# HibiVo アーキテクチャ

> 押す → 話す → 離す → 文章が入る。

## 1. 全体像

```
 HotkeyMonitor (CGEventTap)
      │ pressed / released / interrupted / escape
      ▼
 DictationController  (@MainActor, 状態機械: idle → recording → processing → idle/error)
      │
      ├─ press ─▶ ActiveApplicationService.capture()   … 貼り付け先アプリ・Cleanup Mode をスナップショット
      │          AudioCaptureService.start()  ──AsyncStream<AudioChunk>──▶ TranscriptionSession.send()
      │          provider.makeSession().start()  (接続完了前の音声はセッション内でバッファ)
      │
      └─ release ▶ AudioCaptureService.stop()
                  TranscriptionSession.finish()  … ストリーミング中に大半が確定済み。最後の数百msだけ待つ
                  VocabularyReplacer.apply()     … 辞書の決定的置換
                  CleanupCoordinator.cleanup()   … Mode 決定・プロンプト生成・タイムアウト・出力ガード・Raw フォールバック
                  TextInsertionService.insert()  … クリップボード退避 → ⌘V → 復元
                  HistoryStore.append()          … raw / cleaned / app / provider / latency / status
```

UI（`AppState` を観測）:
- `HUDController` … 非アクティブ化パネル。Recording（レベルメーター）/ Processing / Error のみ
- `MenuBarExtra` … Settings / History / Cleanup Mode / Microphone / STT Provider / Quit
- Settings / History ウィンドウ（SwiftUI）

## 2. 主要な型と責務

| 型 | 種別 | 責務 |
|---|---|---|
| `AppEnvironment` | @MainActor class | コンポジションルート。全サービスを生成して注入。唯一の「全部を知っている」場所 |
| `AppState` | @Observable @MainActor | UI 表示用の状態のみ（phase, audioLevel, partialTranscript, 権限） |
| `SettingsStore` | @Observable @MainActor | UserDefaults に保存する非秘密設定 |
| `KeychainService` | struct (`SecretStore`) | API Key を Keychain に保存 |
| `HotkeyMonitor` | @MainActor class | CGEventTap。イベント解釈は純粋な `HotkeyInterpreter` に委譲 |
| `AudioCaptureService` | @MainActor class | AVAudioEngine。タップ（音声スレッド）→ `PCMConverter` → AsyncStream |
| `TranscriptionProvider` | protocol | プロバイダのメタ情報と、発話ごとの `TranscriptionSession` の生成 |
| `TranscriptionSession` | protocol (actor 実装) | 1発話分のストリーミング接続 |
| `SonioxProvider` | struct + actor | MVP の STT |
| `TextCleanupProvider` | protocol | `system` + `user` を送ってテキストを返すだけ |
| `OpenAICompatibleCleanupProvider` / `AnthropicCleanupProvider` | struct | LLM 呼び出し |
| `CleanupPromptBuilder` | 純粋関数 | Mode + 辞書 + アプリ名からシステムプロンプトを生成 |
| `CleanupOutputGuard` | 純粋関数 | 前置き・`<think>` 除去、長さ比チェック、不正なら nil |
| `CleanupCoordinator` | struct | Mode 決定 → タイムアウト付き LLM 呼び出し → ガード → Raw フォールバック |
| `TextInsertionService` | @MainActor class | Secure Input 確認、対象アプリ再アクティブ化、⌘V、`ClipboardManager` |
| `ClipboardManager` | @MainActor struct | 全 item × 全 type のスナップショット／復元（changeCount 確認） |
| `ActiveApplicationService` | @MainActor struct | 最前面アプリ（bundle id, 名前, pid）の取得 |
| `VocabularyStore` / `HistoryStore` | @MainActor @Observable | メモリ上に保持し、`JSONFileStore`（書き込み actor）で JSON に保存 |
| `DictationContextBuilder` | @MainActor struct | 押下時に設定・Key・辞書・対象アプリの Mode を `DictationContext` に固定 |
| `DictationController` | @MainActor class | 上記を順に呼ぶ状態機械。ロジックは薄く保つ |
| `AppModeRules` | 純粋関数 | bundle id → Mode（ユーザー設定 → 組み込み既定 → 全体既定） |

### TranscriptionProvider インターフェース（提案版）

要件の例 `startStreaming / sendAudio / stopStreaming` をプロバイダ自身に持たせると、
プロバイダが「現在の接続」という可変状態を持つことになり、連続入力時に前の発話と混線しやすい。
そこで **プロバイダ = 設定と生成器、セッション = 1発話** に分けた。

```swift
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var sampleRate: Double { get }            // AudioCapture がこのレートに変換する
    var models: [String] { get }
    func makeSession(_ config: TranscriptionConfig) throws -> any TranscriptionSession
}

public protocol TranscriptionSession: Sendable {
    var partials: AsyncStream<String> { get } // HUD 用（任意）
    func start() async                        // 接続開始。完了を待たずに send してよい
    func send(_ pcm16: Data) async            // 接続前はバッファ
    func finish() async throws -> String      // 確定テキスト
    func cancel() async
}
```

`TranscriptionConfig` は `apiKey / model / language / vocabulary(優先表記の配列)` を持つ。
Deepgram（keyterm）、OpenAI（prompt/keywords）、Soniox（context.terms）はいずれもこの形に収まる。
非ストリーミング API（社内 API 等）は `send` で溜めて `finish` で一括送信すれば同じ protocol で実装できる。

## 3. 並行性

- UI・状態機械・ホットキー・挿入は `@MainActor`。CGEventTap はメインランループに載せる。
- 音声タップはリアルタイムスレッド。`nonisolated static` で作ったクロージャから `AsyncStream.Continuation.yield` するだけ（ロック・アロケーション最小）。
- STT セッションは `actor`。WebSocket 受信ループは actor 内の Task。
- 1発話の処理は `DictationController` が持つ単一の `Task`。キャンセル（Esc・短押し）は Task とセッションを cancel。
- 永続化はストア（@MainActor）が値を持ち、ファイル書き込みだけを actor で行う。世代番号で古い書き込みを捨てる。
- `DispatchQueue` は使わない（`Task.sleep` とタイムアウトは `withThrowingTaskGroup`）。

## 4. データと保存場所

| データ | 保存先 |
|---|---|
| API Key | Keychain（service `io.github.mori-ri.hibivo.api-keys`） |
| 設定 | UserDefaults |
| 辞書 | `~/Library/Application Support/HibiVo/vocabulary.json` |
| 履歴 | `~/Library/Application Support/HibiVo/history.json`（最大200件） |
| 音声 | **保存しない**（メモリ上のみ。セッション終了で破棄） |

## 5. ディレクトリ構成

```
HibiVo/
├── Package.swift                  SwiftPM（Xcode なしでビルド可能）
├── Resources/Info.plist           LSUIElement, NSMicrophoneUsageDescription
├── scripts/
│   ├── build-app.sh               swift build → HibiVo.app を組み立てて署名
│   └── run.sh                     ビルドして起動
├── Sources/
│   ├── HibiVo/HibiVoApp.swift     @main（薄いエントリポイント）
│   └── HibiVoKit/
│       ├── App/                   AppEnvironment, AppDelegate
│       ├── Dictation/             DictationController, AppState
│       ├── Hotkey/                HotkeyTrigger, HotkeyInterpreter, HotkeyMonitor
│       ├── Audio/                 AudioCaptureService, PCMConverter, AudioDeviceCatalog
│       ├── Transcription/         Provider protocol, Soniox
│       ├── Cleanup/               Provider protocol, OpenAI互換, Anthropic, PromptBuilder, OutputGuard, Coordinator
│       ├── Insertion/             TextInsertionService, ClipboardManager
│       ├── Context/               ActiveApplicationService, AppModeRules
│       ├── Vocabulary/            VocabularyEntry, VocabularyStore, VocabularyReplacer
│       ├── History/               HistoryRecord, HistoryStore
│       ├── Settings/              SettingsStore, KeychainService
│       ├── Support/               Permissions, UserFacingError, JSONFileStore
│       └── UI/                    HUD/, MenuBar/, Settings/, History/
├── Tests/HibiVoKitTests/          Swift Testing
└── docs/                          ARCHITECTURE.md, DECISIONS.md
```

## 6. 実装計画

| Phase | 内容 | 完了確認 |
|---|---|---|
| 1 | Menu Bar / Hotkey / Audio Capture / HUD | ビルド、HotkeyInterpreter の単体テスト、実機でキー押下 → HUD とレベル表示 |
| 2 | Soniox Streaming STT（日本語、context.terms） | メッセージ組み立てと token 解析のテスト、Mock プロバイダでの controller テスト、実キーで実機確認 |
| 3 | Text insertion / Clipboard 復元 | 複数 item・画像・RTF の往復テスト、changeCount 競合テスト、主要アプリで貼り付け |
| 4 | LLM Cleanup（Raw / Natural / Business / Prompt） | プロンプト生成・出力ガード・タイムアウト→Raw のテスト |
| 5 | Vocabulary / History / Settings | 置換テスト、履歴の上限・永続化テスト、Settings UI |
| 6 | App-aware Cleanup | bundle id → Mode 解決のテスト、既定マップ（Terminal/Cursor→Prompt 等） |

## 7. 技術リスク

| リスク | 影響 | 対策 |
|---|---|---|
| ad-hoc 署名で再ビルドごとにアクセシビリティ許可が外れる | 開発時にホットキーが効かない | 安定した署名 ID を優先使用、`tccutil reset` 手順を README に記載、メニューに権限状態を表示 |
| Fn キーが 🌐 のシステム機能と衝突 | 絵文字パレット等が開く | 既定は右 Option。Fn 選択時は設定変更を案内 |
| アプリにより ⌘V の反映が遅く、復元が早すぎると旧クリップボードが貼られる | 誤入力 | 復元まで 350ms、changeCount 確認。問題アプリは遅延を延長可能な設計 |
| Secure Input 中は合成キーが届かない | 入力されない | 検出して「クリップボードにコピーしました」と表示 |
| STT の確定シグナルが来ない | 待ちが長い | finish にタイムアウト（既定 4s）→ それまでの final tokens で確定 |
| LLM の遅延・意味改変 | KPI 悪化・誤情報 | タイムアウト（既定 5s）→ Raw、出力ガード、temperature 0、「意味を追加しない」制約 |
| Bluetooth マイクの立ち上がり遅延 | 冒頭の取りこぼし | 押下と同時に開始し、バッファで吸収。README で有線/内蔵マイク推奨 |
| Xcode 未導入環境 | xcodebuild が使えない | SwiftPM + スクリプトで .app を組み立てる構成にした |
| 実キーでの STT/LLM は API Key が必要 | 自動テストで E2E が不可能 | プロバイダを protocol 化し Mock でパイプライン全体をテスト。実 API は手動確認 |

## 8. macOS 特有の注意点

- **権限**: CGEventTap（能動タップ）と ⌘V の送出にアクセシビリティ権限、録音にマイク権限が必要。
- **TCC と署名**: ad-hoc 署名は再ビルドのたびに cdhash が変わり、アクセシビリティ許可が無効化される。安定した署名 ID を使うか、開発中は `tccutil reset Accessibility io.github.mori-ri.hibivo` で再許可する。
- **Fn(🌐) キー**: システム設定「🌐キーを押して」が「絵文字」や「音声入力」だと同時に発火する。「何もしない」を推奨。flagsChanged の keyCode 63 + `maskSecondaryFn` で検出。
- **修飾キーのイベントは握りつぶさない**: flagsChanged を消費するとシステムの修飾キー状態がずれる。
- **⌘V の送出**: `CGEventSource(.hidSystemState)`、仮想キー 0x09（物理位置なので JIS/US 配列に依存しない）。
- **Swift 6 と音声スレッド**: `@MainActor` メソッド内で作ったクロージャを `installTap` に渡すと、リアルタイムスレッドで isolation チェックに引っかかりクラッシュする。タップブロックは nonisolated な文脈で作る。
- **Bluetooth マイク**: AirPods は入力開始時に HFP へ切り替わり、数百ms遅れることがある。
- **LSUIElement**: Dock に出さない。ウィンドウを開く際は `NSApp.activate` が必要。

## 9. 実装状況（v0.1）

| Phase | 状態 | 自動テスト | 手動確認が必要なこと |
|---|---|---|---|
| 1 Menu Bar / Hotkey / Audio / HUD | 実装済み | HotkeyInterpreter（keyDown/keyUp、左右 Option、Fn、⌃Space、Esc、他キー割り込み） | 実キーでの押下 → HUD 表示、レベルメーター |
| 2 Soniox Streaming STT | 実装済み | 設定メッセージ、token 集約、`<fin>`、エラー応答。実エンドポイントへ接続し不正 Key が 401 で拒否されることを確認 | 有効な Key で日本語の文字起こし |
| 3 挿入 / クリップボード復元 | 実装済み | 日本語・改行・絵文字・URL・メール・英数字、複数 item・RTF・画像の復元、途中コピー時に上書きしない | Safari / Chrome / Slack / Teams / VS Code / Cursor / Terminal / ChatGPT での貼り付け |
| 4 LLM Cleanup | 実装済み | プロンプト、出力ガード、タイムアウト → Raw、API 失敗 → Raw、リクエスト/レスポンス形式 | 有効な Key での整形品質 |
| 5 辞書 / 履歴 / 設定 | 実装済み | 置換、履歴の上限・永続化・失敗記録、辞書の永続化 | 設定画面・履歴画面の操作 |
| 6 App-aware Cleanup | 実装済み | 組み込み既定、ユーザー上書き、Context への反映 | 実アプリでのモード切替 |
