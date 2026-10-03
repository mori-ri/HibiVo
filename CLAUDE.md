# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

HibiVo は日本語優先の macOS メニューバー常駐型音声入力アプリ。ホットキーを押して話し、もう一度押すと、(必要に応じて LLM で整形した)テキストが直前にフォーカスしていたアプリのカーソル位置に貼り付けられる。Swift 6 / SwiftUI 製で、ビルドは SwiftPM のみ。Xcode プロジェクトは存在しない。

## コマンド

必ずスクリプト経由で実行すること。スクリプトは `scripts/env.sh` を読み込み、Command Line Tools のみのツールチェーン向けの回避策を適用する(「この環境特有の注意点」を参照)。

```sh
scripts/test.sh                                        # 全テスト (Swift Testing)
scripts/test.sh --filter HotkeyInterpreterTests        # 1 スイートのみ
scripts/test.sh --filter "DictationControllerTests/shortTapIsCancelled"   # 1 テストのみ
HIBIVO_INTEGRATION=1 scripts/test.sh --filter SonioxIntegration           # 実際の Soniox エンドポイントに接続 (オプトイン)
HIBIVO_INTEGRATION=1 scripts/test.sh --filter GeminiIntegration           # 実際の Gemini エンドポイントに接続 (オプトイン、GEMINI_API_KEY)

scripts/run.sh                          # debug ビルド → build/HibiVo.app → 起動 (起動中のアプリは終了させる)
CONFIG=release scripts/build-app.sh     # build/HibiVo.app を組み立てて署名
scripts/package.sh                      # release ビルド → build/HibiVo-<ver>-<arch>.zip (ditto で署名を保持)
scripts/release.sh prepare 0.3.0        # リリース準備: Info.plist のバージョンと build 番号を上げて PR を作る (release/* 上では直接コミット)
scripts/release.sh publish              # マージ後の main (か release/*) でタグを push し、ノート自動生成付きのリリース下書きを作る
scripts/create-signing-cert.sh          # 初回のみ: ログインキーチェーンに自己署名証明書 "HibiVo Self-Signed" を作成
swift scripts/make-icons.swift          # Resources/AppIconSource.png から AppIcon.icns、Logo*.png、MenuBarIcon*.png を再生成
scripts/format.sh                       # swift-format で整形 (その場で書き換え)
scripts/lint.sh                         # swift-format lint --strict (CI でも実行)
```

フォーマッタ・リンタは toolchain 同梱の swift-format(`swift format`)のみ。設定は `.swift-format`(4 スペース・120 桁)。Swift ファイルを変更したら `scripts/format.sh` をかけ、`scripts/lint.sh` が通ることを確認する。

## この環境特有の注意点

- **CLT のみの環境では macOS 26 SDK が必要。** macOS 27 SDK では SwiftUI の `@State` がマクロになっており、そのプラグインは Xcode にしか同梱されていない。`xcode-select -p` が CommandLineTools を指している場合、`scripts/env.sh` が `SDKROOT` を 26 SDK に設定する。素の `swift build` は "plugin for module 'SwiftUIMacros' not found" で失敗する。コードでは通常どおり `@State` を使い続けること。
- **Swift Testing マクロの不安定な失敗。** CLT のみの環境では、テストファイル変更後の初回コンパイルが "plugin for module 'TestingMacros' not found" で失敗することがある。再ビルドすれば成功するため、`scripts/test.sh` はビルドを最大 3 回リトライする。
- **アクセシビリティ権限 (TCC) はアドホック署名で再ビルドするたびにリセットされる。** cdhash が変わるため。自己署名証明書がない場合、ユーザーは `build-app.sh` のたびに権限を再付与する必要がある。復旧方法は `tccutil reset Accessibility io.github.mori-ri.hibivo`。`build-app.sh` は "HibiVo Self-Signed" 証明書(または `HIBIVO_SIGN_IDENTITY`)があれば自動的に使用する。
- バンドル ID `io.github.mori-ri.hibivo` は Keychain のサービス名プレフィックス(`…api-keys`)および `Logger` の subsystem も兼ねている。変更するとユーザーが保存したキーや権限が参照できなくなる。
- リソース(アイコン)は SwiftPM リソースではない。`build-app.sh` が `Contents/Resources` にコピーし、コードは `NSImage(named:)` で読み込む。`swift run` 実行時には存在しないため、コードは SF Symbols にフォールバックする。

## アーキテクチャ

`@main` 以外はすべて `HibiVoKit` ライブラリにあり(`Sources/HibiVo/HibiVoApp.swift` は薄いエントリポイント)、テストから `@testable import` できる。`AppEnvironment` が唯一のコンポジションルートで、各サービスは依存を注入される。シングルトンは使わない。

**音声入力フロー**(`Dictation/DictationController.swift`、`@MainActor` のステートマシン: idle → recording → processing → idle/error):

1. `HotkeyMonitor` がメインランループ上でアクティブな CGEventTap を動かす。判定ロジックは純粋関数的な `HotkeyInterpreter`。修飾キーのトリガーはデバイス依存のフラグビットを使い、左右のキーを区別する。押し始めに他キーと同時押しした場合や Esc でキャンセル。押すと録音開始、録音中に押すと終了。`holdThreshold`(0.4 秒)以上押し続けて離した場合は離した時点で終了し(プッシュトゥトーク)、それより短ければ次に押すまで録音を続ける。
2. 録音開始時、`DictationContextBuilder.make(target:)` がこの発話に必要なものをすべて `DictationContext` に固定する: 対象アプリ、STT 設定とキー、そのアプリの整形モード、認証情報付きの整形プロバイダ、語彙。発話中に設定が変わっても混ざらない。
3. `AudioCaptureService`(録音ごとに新しい AVAudioEngine)が PCM16 モノラルのチャンクを `AsyncStream<AudioChunk>` として流す。ポンプタスクが発話中にそれを STT セッションへ転送する。
4. 録音終了時: 250 ms 未満で止めた場合(誤ったダブルタップ)はキャンセル、無音(ピーク RMS が閾値未満)はアップロードをスキップ。その後 `session.finish()`、`VocabularyReplacer`、`CleanupCoordinator.run`、`TextInsertionService.insert`、`HistoryStore.append` の順に実行する。

**ミーティングモード**(`Meeting/MeetingController.swift`): トリガー + M(`HotkeyAction.meeting`)で開始し、次のトリガーの `.released` で終了する。`.pressed`・`.interrupted`・Esc は無視する(Fn + ← などで誤って終了しないため)。
- `AppEnvironment` は、ミーティング中は操作を `MeetingController` に回す。開始時は、トリガーの押下で始まった音声入力をキャンセルしてから開始する。
- 音声は、マイクと、設定で有効なときはシステム音声(`SystemAudioCaptureService`)。システム音声は Core Audio の process tap(macOS 14.2 以降)を private なアグリゲートデバイスに入れて IO proc で読む。必要なのは「システムオーディオ録音」の権限だけで、拒否されていても例外は出ず、無音が届く。
- 2 つの音源は `PCMMixer` で 1 本の PCM16 にミックスし、1 つの STT セッションに送る(料金は 1 本分)。片方が止まったときは、300 ms を超えた分を無音で埋めて送る。送信は 1 本のキューで順序を保つ。
- STT は常に Soniox(`MeetingTranscriptionProvider`)で、話者識別(`enable_speaker_diarization`)を有効にする。辞書は音声入力と同じく、表記と読み(`readings`)をヒントとして渡す(非同期の場合も同じ)。`SonioxSession` は話者識別が有効なときだけ `events` にトークンを流し、文字列は溜めない。
- `MeetingTranscript`(純粋関数的)が、話者の切り替わりと 4 秒以上の間で段落に分ける。`MeetingDocument` が Markdown に変換する。話者は登場順に「話者1」「話者2」… と番号を振る。再接続後のセッションの話者には新しい番号を振る。ファイルは `Application Support/HibiVo/Meetings/` に数秒ごとにアトミックに書き直す。
- セッションが切れたら再接続する(不正なキーの場合を除く)。新しいセッションの時刻は、それまでに送った音声の長さだけずらす。話者番号はセッションごとに振り直される。
- 「終了後にまとめて」モード(`MeetingTranscriptionTiming.afterMeeting`)では STT セッションを開かず、ミックスした PCM をメモリに溜める。終了後に `SonioxFileTranscriber`(非同期 API `stt-async-v5`: アップロード → 作成 → ポーリング → 取得 → ファイルと文字起こしの削除)で処理する。WAV はメモリ上で組み立てる。バックグラウンドで実行し、録音が終わった時点でホットキーは解放する。一時的な失敗は 3 回まで再試行する。
- 保存後、設定で有効なら `ClaudeCodeMinutesWriter` が Claude Code CLI を `claude -p --output-format json --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --system-prompt …` で実行し、議事録を書く。ファイル名は `<開始日時>_<タイトル>.md` で、タイトルは議事録の 1 行目(`# …`)として Claude に書かせたものを `MeetingMinutesTitle` がファイル名に使える形に整える。取れなかった場合は `_議事録`。プロンプトのうち議事録の内容と書き方の部分(`MeetingMinutesPrompt.defaultInstructions`)は設定で編集でき(`instructionsLimit` 文字まで、nil・空欄・既定と同じ文はデフォルト扱い)、タイトル行・辞書・インジェクション対策・出力形式の指示は固定。ユーザー辞書は通常の整形と同じ形式(`CleanupPromptBuilder.vocabularyLines`)で、`<vocabulary>` として文字起こしの前に渡す。サブスクリプションの枠を使うため、子プロセスの環境から `ANTHROPIC_API_KEY` を取り除き、`--bare`(OAuth を読まない)は使わない。GUI アプリは PATH を引き継がないので、実行ファイルは標準のインストール先から探す。Finder は議事録ができてから 1 回だけ開く。
- 貼り付け・整形・ダッキングは行わない。システムのスリープは抑止し、4 時間で自動終了する。

**辞書**(`Vocabulary/`): `VocabularyReplacer` は、聞き取り例(`spoken` と `aliases`)を表記(`preferred`)に置き換える。照合は `KanaFolding` で 1 文字ずつ正規化して行う(NFKC で全角英数字と半角カナを揃え、平仮名を片仮名に、ヂ・ヅをジ・ズに)。英数字と仮名の境目の空白は、あってもなくても一致とする(Soniox は英単語の前後に空白を入れるため)。「ー」「・」、それ以外の空白、改行は区別する(「バッター」と「バッタ」のように語を分けるため)。置き換えなかった部分の表記は変えない。2 文字以下の仮名だけの聞き取り例(「あい」→ AI など)は一般的な言葉と区別できないため置き換えず、STT の読みにも含めない。整形プロンプトにだけ「文脈で判断する」という注記付きで渡す(`VocabularyEntry.contextualForms`)。STT には、表記(`TranscriptionConfig.vocabulary`)に加えて、聞き取り例を片仮名にした読み(`readings`)も渡す。Soniox は表記を先に、重複を除いて 200 語までを `context.terms` に入れる。Gemini には表記だけを渡す。

**修正からの辞書学習**: 貼り付けに成功したら、`CorrectionWatcher` が対象アプリのフォーカス中の入力欄を AX で 0.5 秒ごとに読み、ユーザーが直した結果を追う(`AXManualAccessibility` で Electron にもツリーを作らせる)。`InsertedTextTracker` は、貼り付け直後のキャレット位置から挿入の前後のテキストを覚え、それが変わらない間はその間を挿入部分とみなす。フォーカスの移動、アプリの切り替え、欄が空になったとき、次の音声入力の開始、45 秒のいずれかで終わり、`CorrectionLearner` に渡す。`CorrectionExtractor`(純粋関数的)は文字単位の差分を取り、変更箇所を前後の英字・片仮名・漢字の連続まで広げて語にする(平仮名は助詞や送り仮名なので広げない)。書き直し、数字、句読点、送り仮名、名詞以外(動詞・形容詞の語幹。システムのトークナイザーが送り仮名ごと 1 語にするかで判定する)、表記だけの違い、短い仮名、音が似ていない組(システムの形態素解析のローマ字読みの子音で比べる。略語は除く)は捨てる。登録は `VocabularyStore.learn`(同じ表記があれば別名に追加、ほかの項目と取り合う形は登録しない)で、HUD に専用のカード(`LearnedNotice`)を 10 秒表示し、ポインタを重ねている間は消さない。クリックで取り消せる。AX で読めないアプリ向けに、履歴の「修正」でも同じ抽出を行い、候補をボタンで追加できる。入力欄のテキストは保存しない。

**STT 抽象化**(`Transcription/`): `TranscriptionProvider` はステートレスで、発話ごとに `TranscriptionSession`(actor)を 1 つ作るだけ。そのため連続した音声入力でストリームが混線しない。セッションはソケット接続前の `send` を受け付けてバッファする。実装は 2 つ。どちらもタイムアウトや切断時は例外を投げずに途中までのテキストを返す。
- Soniox(`stt-rt-v5`): `finalize` → `<fin>` トークンを待つ。
- Gemini(`gemini-3.5-transcribe-live`、Live API): 手動 VAD。`setupComplete` まで音声をバッファし、`activityStart` → 音声 → `activityEnd` を送る。確定した `inputTranscription` のセグメントを連結し、`turnComplete` と最後のセグメント(順序は保証されない)が揃うか、少し待って終了する。不正なキーはソケットの close 理由で届く。API キー(Keychain の `gemini`)は整形の Gemini と共通。

**整形 (Cleanup)**(`Cleanup/`):
- `TextCleanupProvider.complete(system:user:model:)`。Bedrock はキーペアが必要なため、各プロバイダは自身の認証情報を持って生成される。
- `CleanupCoordinator` は発話を決して失わない: raw モード、プロバイダなし(nil = 認証情報なし)、エラー、5 秒タイムアウト、`CleanupOutputGuard` による棄却のいずれでも、生の文字起こしと `failure` を返す。
- プロンプトは純粋関数的な `CleanupPromptBuilder` が生成する。文字起こしは `<transcript>` で囲まれ、モデルが内容に回答せず書き直すようにしている。
- Custom モードは、設定の「カスタム指示」(`SettingsStore.customCleanupInstructions`、`CleanupMode.customInstructionsLimit` 文字まで)を `<instructions>` として基本の整形ルールに加える。指示は録音開始時に `DictationContext.Cleanup` に固定する。
- プロバイダ:
  - Anthropic Messages(`output_config.effort: low`、Opus 5 / Fable 5 向けにサーバー側 `fallbacks`)。
  - OpenAI 互換の chat completions。
  - Gemini Interactions API(`thinking_level: low`、`store: false`)。既定は `gemini-3.8-flash`。
  - `BedrockCleanupProvider`: `anthropic.` を含むモデル ID は Anthropic のリクエストボディで InvokeModel を使う。それ以外のモデル(GLM、MiniMax、GPT など)は Converse API を使う。認証は Bedrock API キー(Bearer)か、自前の `AWSSigV4`(CryptoKit 実装、AWS テストスイートのベクタで検証済み)で署名する IAM キー。
- プロバイダ種別、デフォルトモデル、Keychain のアカウント名は `CleanupProviderKind` / `SecretAccount`(`TextCleanupProvider.swift`)に集約されている。

**アプリ別モード**: `AppModeRules` は、ユーザーのアプリ別設定(`appModeOverrides`)→ グローバルデフォルトの順でモードを解決する。初回起動時に `AppModeRules.initialOverrides`(Terminal → Prompt、Mail → Business)を一度だけ設定に追加する(`appModeOverridesSeeded`)。追加した後は通常の項目として変更・削除できる。

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
- 押し続けた時間は、処理した時刻ではなくキーイベントが起きた時刻(`HotkeyMonitor` が `NSEvent.timestamp` から求める)で測る。音声エンジンの起動中は離したイベントが待たされるため、処理時刻で測るとショートタップが長押しと判定されて録音がすぐ止まる。
- `DictationController.waitUntilIdle()` は実行中の processing / cancel タスクを await する。テストでは sleep の代わりにこれを使う。

## 規約

- ユーザー向けテキストは日本語で、ステータスコードではなくユーザーに伝わる言い回しにする。エラーは `UserFacingError` を経由させる。コードコメントは英語。
- テストは Swift Testing(`@Test`、`#expect`)を使う。モックは `Tests/HibiVoKitTests/Mocks.swift` にある。`#require` の中に `#require` をネストしない(マクロ再帰エラーになる)。
- 自明でない設計判断はローカル専用の `notes/DECISIONS.md`(番号付きの表)に記録する。詳しい設計と macOS 関連のメモは `notes/ARCHITECTURE.md` にある。どちらもクローンには含まれない。
- `notes/` はローカル専用(`.git/info/exclude` で除外)。その内容を追跡対象のファイルに移さないこと。
- アプリアイコンとロゴのファイルは MIT ライセンスの対象外(README 参照)。出力ファイルを直接編集せず、`make-icons.swift` で再生成すること。
