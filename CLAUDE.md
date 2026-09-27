# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

HibiVo は日本語優先の macOS メニューバー常駐型プッシュトゥトーク音声入力アプリ。ホットキーを押して話し、離すと、(必要に応じて LLM で整形した)テキストが直前にフォーカスしていたアプリのカーソル位置に貼り付けられる。Swift 6 / SwiftUI 製で、ビルドは SwiftPM のみ。Xcode プロジェクトは存在しない。

## コマンド

必ずスクリプト経由で実行すること。スクリプトは `scripts/env.sh` を読み込み、Command Line Tools のみのツールチェーン向けの回避策を適用する(「この環境特有の注意点」を参照)。

```sh
scripts/test.sh                                        # 全テスト (Swift Testing)
scripts/test.sh --filter HotkeyInterpreterTests        # 1 スイートのみ
scripts/test.sh --filter "DictationControllerTests/shortTapIsCancelled"   # 1 テストのみ
HIBIVO_INTEGRATION=1 scripts/test.sh --filter SonioxIntegration           # 実際の Soniox エンドポイントに接続 (オプトイン)

scripts/run.sh                          # debug ビルド → build/HibiVo.app → 起動 (起動中のアプリは終了させる)
CONFIG=release scripts/build-app.sh     # build/HibiVo.app を組み立てて署名
scripts/package.sh                      # release ビルド → build/HibiVo-<ver>-<arch>.zip (ditto で署名を保持)
scripts/create-signing-cert.sh          # 初回のみ: ログインキーチェーンに自己署名証明書 "HibiVo Self-Signed" を作成
swift scripts/make-icons.swift          # Resources/AppIconSource.png から AppIcon.icns、Logo*.png、MenuBarIcon*.png を再生成
```

リンターやフォーマッターは設定されていない。

## この環境特有の注意点

- **CLT のみの環境では macOS 26 SDK が必要。** macOS 27 SDK では SwiftUI の `@State` がマクロになっており、そのプラグインは Xcode にしか同梱されていない。`xcode-select -p` が CommandLineTools を指している場合、`scripts/env.sh` が `SDKROOT` を 26 SDK に設定する。素の `swift build` は "plugin for module 'SwiftUIMacros' not found" で失敗する。コードでは通常どおり `@State` を使い続けること。
- **Swift Testing マクロの不安定な失敗。** CLT のみの環境では、テストファイル変更後の初回コンパイルが "plugin for module 'TestingMacros' not found" で失敗することがある。再ビルドすれば成功するため、`scripts/test.sh` はビルドを最大 3 回リトライする。
- **アクセシビリティ権限 (TCC) はアドホック署名で再ビルドするたびにリセットされる。** cdhash が変わるため。自己署名証明書がない場合、ユーザーは `build-app.sh` のたびに権限を再付与する必要がある。復旧方法は `tccutil reset Accessibility io.github.mori-ri.hibivo`。`build-app.sh` は "HibiVo Self-Signed" 証明書(または `HIBIVO_SIGN_IDENTITY`)があれば自動的に使用する。
- バンドル ID `io.github.mori-ri.hibivo` は Keychain のサービス名プレフィックス(`…api-keys`)および `Logger` の subsystem も兼ねている。変更するとユーザーが保存したキーや権限が参照できなくなる。
- リソース(アイコン)は SwiftPM リソースではない。`build-app.sh` が `Contents/Resources` にコピーし、コードは `NSImage(named:)` で読み込む。`swift run` 実行時には存在しないため、コードは SF Symbols にフォールバックする。

## アーキテクチャ

`@main` 以外はすべて `HibiVoKit` ライブラリにあり(`Sources/HibiVo/HibiVoApp.swift` は薄いエントリポイント)、テストから `@testable import` できる。`AppEnvironment` が唯一のコンポジションルートで、各サービスは依存を注入される。シングルトンは使わない。

**音声入力フロー**(`Dictation/DictationController.swift`、`@MainActor` のステートマシン: idle → recording → processing → idle/error):

1. `HotkeyMonitor` がメインランループ上でアクティブな CGEventTap を動かす。判定ロジックは純粋関数的な `HotkeyInterpreter`。修飾キーのトリガーはデバイス依存のフラグビットを使い、左右のキーを区別する。他キーとの同時押しや Esc でキャンセル。
2. 押下時、`DictationContextBuilder.make(target:)` がこの発話に必要なものをすべて `DictationContext` に固定する: 対象アプリ、STT 設定とキー、そのアプリの整形モード、認証情報付きの整形プロバイダ、語彙。発話中に設定が変わっても混ざらない。
3. `AudioCaptureService`(録音ごとに新しい AVAudioEngine)が PCM16 モノラルのチャンクを `AsyncStream<AudioChunk>` として流す。ポンプタスクが発話中にそれを STT セッションへ転送する。
4. 離したとき: 短いタップ(< 250 ms)はキャンセル、無音(ピーク RMS が閾値未満)はアップロードをスキップ。その後 `session.finish()`、`VocabularyReplacer`、`CleanupCoordinator.run`、`TextInsertionService.insert`、`HistoryStore.append` の順に実行する。

**STT 抽象化**(`Transcription/`): `TranscriptionProvider` はステートレスで、発話ごとに `TranscriptionSession`(actor)を 1 つ作るだけ。そのため連続した音声入力でストリームが混線しない。セッションはソケット接続前の `send` を受け付けてバッファする。実装は Soniox(`stt-rt-v5`)のみ: `finalize` → `<fin>` トークンを待ち、タイムアウトや切断時は例外を投げずに途中までのテキストを返す。

**整形 (Cleanup)**(`Cleanup/`):
- `TextCleanupProvider.complete(system:user:model:)`。Bedrock はキーペアが必要なため、各プロバイダは自身の認証情報を持って生成される。
- `CleanupCoordinator` は発話を決して失わない: raw モード、プロバイダなし(nil = 認証情報なし)、エラー、5 秒タイムアウト、`CleanupOutputGuard` による棄却のいずれでも、生の文字起こしと `failure` を返す。
- プロンプトは純粋関数的な `CleanupPromptBuilder` が生成する。文字起こしは `<transcript>` で囲まれ、モデルが内容に回答せず書き直すようにしている。
- プロバイダ:
  - Anthropic Messages(`output_config.effort: low`、Opus 5 / Fable 5 向けにサーバー側 `fallbacks`)。
  - OpenAI 互換の chat completions。
  - `BedrockCleanupProvider`: `anthropic.` を含むモデル ID は Anthropic のリクエストボディで InvokeModel を使う。それ以外のモデル(GLM、MiniMax、GPT など)は Converse API を使う。認証は Bedrock API キー(Bearer)か、自前の `AWSSigV4`(CryptoKit 実装、AWS テストスイートのベクタで検証済み)で署名する IAM キー。
- プロバイダ種別、デフォルトモデル、Keychain のアカウント名は `CleanupProviderKind` / `SecretAccount`(`TextCleanupProvider.swift`)に集約されている。

**アプリ別モード**: `AppModeRules` は次の順でモードを解決する: ユーザーの上書き設定 → 組み込みのバンドル ID 別デフォルト(ターミナル/IDE/ChatGPT → Prompt、Slack/Teams → Natural、Mail/Outlook → Business)→ グローバルデフォルト。

**挿入**(`Insertion/`): Electron/ブラウザ/ターミナルとの互換性のため、AX での値設定ではなくクリップボード + ⌘V(仮想キー 0x09)を使う。
- `ClipboardManager` はすべてのアイテム × すべてのタイプをスナップショットし、自身の書き込みには `org.nspasteboard.TransientType` を付ける。
- 350 ms 後、`changeCount` が変わっていない場合のみ復元する。
- Secure Input、アクセシビリティ権限なし、対象アプリ終了済みの場合は、説明付きでコピーのみにする。

**状態と永続化**:
- `AppState` は UI 状態のみを保持する。
- `SettingsStore` は秘密情報以外の設定を UserDefaults に保存する。
- 秘密情報は `SecretStore` / `KeychainService` 経由で Keychain にのみ保存する。
- `VocabularyStore` / `HistoryStore` は `@MainActor @Observable` なインメモリストアで、`JSONFileStore`(`~/Library/Application Support/HibiVo/`)経由で保存する。書き込み用 actor は古い世代を破棄するため、並行保存でファイルが巻き戻らない。
- `UsageStore` は日別の利用集計(回数・文字数・送信音声秒数・モデル別トークン)を `usage.json` に保存する。テキストは持たず、履歴の設定とは独立。料金の概算は `UsagePricing` の公開価格表から計算する。
- 音声はディスクに一切書き込まない。

## 過去に問題になった並行性ルール

- AVAudioEngine のタップブロックは `nonisolated` なコンテキストで作ること(`AudioCaptureService.makeTapBlock`)。`@MainActor` メソッド内で作ったクロージャは、Swift 6 ではリアルタイム音声スレッド上でトラップする。
- CGEventTap の C コールバックは、`MainActor.assumeIsolated` の前にイベントのフィールドを Sendable な `KeyEvent` にコピーする。
- ホットキーのアクションはタップコールバックの外、`Task { @MainActor }` で処理する。コールバックが遅い(Bluetooth マイクでのエンジン起動など)と macOS がタップを無効化してしまう。
- `DictationController.waitUntilIdle()` は実行中の processing / cancel タスクを await する。テストでは sleep の代わりにこれを使う。

## 規約

- ユーザー向けテキストは日本語で、ステータスコードではなくユーザーに伝わる言い回しにする。エラーは `UserFacingError` を経由させる。コードコメントは英語。
- テストは Swift Testing(`@Test`、`#expect`)を使う。モックは `Tests/HibiVoKitTests/Mocks.swift` にある。`#require` の中に `#require` をネストしない(マクロ再帰エラーになる)。
- 自明でない設計判断はローカル専用の `notes/DECISIONS.md`(番号付きの表)に記録する。詳しい設計と macOS 関連のメモは `notes/ARCHITECTURE.md` にある。どちらもクローンには含まれない。
- `notes/` はローカル専用(`.git/info/exclude` で除外)。その内容を追跡対象のファイルに移さないこと。
- アプリアイコンとロゴのファイルは MIT ライセンスの対象外(README 参照)。出力ファイルを直接編集せず、`make-icons.swift` で再生成すること。
