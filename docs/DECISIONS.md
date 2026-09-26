# 判断ログ

確認待ちで止まらないために、自分で決めたことと理由を短く残す。

| # | 判断 | 理由 |
|---|---|---|
| 1 | Xcode プロジェクトではなく SwiftPM + `.app` 組み立てスクリプト | 開発機に Xcode が無く、CLT だけで SwiftUI のビルドと Swift Testing が動くことを確認済み。差分がレビューしやすい |
| 2 | ロジックは `HibiVoKit` ライブラリ、`HibiVo` 実行ターゲットは @main のみ | テストから import できるようにするため |
| 3 | 最初の STT は Soniox（`stt-rt-v5`） | 日本語の精度評価が最も高い、`language_hints: ["ja","en"]` で英単語混在に強い、`context.terms` で辞書を渡せる、`finalize` → `<fin>` で確定が明確、16kHz PCM をバイナリで送るだけで簡単 |
| 4 | Provider と Session を分離 | 連続入力時の混線防止。Session は actor で1発話だけを持つ |
| 5 | 既定ホットキーは右 Option | Fn は 🌐 のシステム機能と衝突しやすい。Fn も設定で選べる |
| 6 | 押してから 250ms 未満で離したらキャンセル | 修飾キーの単打や誤タッチで空の貼り付けをしない |
| 7 | 修飾キー押下中に他のキーが押されたらキャンセル | ⌥+文字、⌘+C などの通常操作を妨げない |
| 8 | 処理中（Processing）に押されたホットキーは無視 | 貼り付け順序の競合を避ける。処理は通常1秒前後 |
| 9 | テキスト挿入はクリップボード + ⌘V を主経路にする。AX 直接挿入は MVP では使わない | Chrome / Electron / Terminal で AX の `kAXSelectedText` 設定は成功を返しても反映されないことがあり、互換性を優先 |
| 10 | クリップボードの復元は 350ms 後、`changeCount` が変わっていたら復元しない | Electron / Slack で 100ms では早すぎる。ユーザーが途中でコピーした内容を上書きしない |
| 11 | 自分が書き込むクリップボードには `org.nspasteboard.TransientType` を付ける | クリップボード履歴アプリに記録させない |
| 12 | LLM は OpenAI 互換 Chat Completions と Anthropic Messages の2種 | OpenAI 互換で OpenAI / Groq / OpenRouter / 社内 API を網羅。Claude は別形式のため1つ追加 |
| 13 | Cleanup のタイムアウトは 5 秒、失敗したら Raw を貼る | 発話を失わない。KPI（離してから入力まで）を守る |
| 14 | 履歴・辞書は @MainActor の @Observable ストア + JSON ファイル。書き込みはバックグラウンドの actor で、世代番号の古い書き込みは捨てる | 200件程度なら十分速い。UI から同期的に読める。並行保存で古い内容が後勝ちする競合をテストで検出したため世代番号を導入。SwiftData はマクロに Xcode が必要で過剰 |
| 15 | 音声は保存しない。そのため履歴の Retry は「Retry Cleanup」のみ | 要件 17（プライバシー）を優先 |
| 16 | 無音（RMS のピークが閾値未満）ならアップロードも貼り付けもしない | 誤押下で空文字や幻聴テキストを入れない |
| 17 | Command Line Tools のみの環境では macOS 26 SDK でビルド（`scripts/env.sh`） | macOS 27 SDK では SwiftUI の `@State` がマクロになり、そのプラグインが Xcode にしか同梱されていない。コードは通常の `@State` のまま保ち、SDK 側で回避する |
| 18 | Anthropic の既定モデルは `claude-opus-5`、`output_config.effort: "low"`、`fallbacks: "default"`（`server-side-fallback-2026-07-01`） | 最新の推奨モデル。整形は軽い書き換えなので effort を下げて遅延を抑える。安全分類器による拒否時もサーバー側で別モデルに切り替わる。遅延が気になる場合は設定でモデルを変更可能（例: `claude-haiku-4-5`） |
| 19 | ホットキーの処理はタップのコールバック外（MainActor の Task）で行う | 音声エンジンの起動が遅いとシステムがイベントタップを無効化するため |
| 20 | 録音は最大 10 分で自動終了 | キーを離すイベントを取りこぼしても録音し続けない |
| 21 | 未知のアプリの既定モードは Natural | 要件 12 の「その他 → Natural」に従う |
| 22 | Gmail などブラウザ内のアプリは bundle id で区別できないため、ブラウザの既定モードに従う | URL の取得は AX 依存で不安定。MVP では扱わない |
| 23 | 配布はソース公開＋各自ビルドを基本とし、仲間内には `scripts/package.sh` の zip を渡す。署名は自己署名証明書（`create-signing-cert.sh`） | ローカルビルドは quarantine が付かず Gatekeeper の警告が出ない。自己署名でも証明書が固定ならアクセシビリティ許可がアップデート後も保たれる。Developer ID ＋公証（年 $99）は利用者が増えてから検討 |
| 24 | Amazon Bedrock は `bedrock-runtime` の InvokeModel（Anthropic Messages 形式）で接続。認証は Bedrock API キー（Bearer）か IAM アクセスキー（自前の SigV4 実装）。 | 既存の Bedrock の IAM 権限（`bedrock:InvokeModel`）・運用に合わせる。AWS SDK を入れずに済むよう SigV4 は CryptoKit で実装し、AWS 公式テストベクタで検証。最新 Claude モデルは InvokeModel で提供されるため Claude は InvokeModel のまま |
| 25 | Bedrock の Claude 以外のモデル（GLM、MiniMax、GPT など）は Converse API で呼ぶ。モデル ID に `anthropic.` を含むかで InvokeModel / Converse を切り替える | Converse は AWS ネイティブで SigV4・API キーの両方が使え、推論過程（`reasoningContent`）が本文と別ブロックで返るため整形結果に混ざらない。temperature は一部推論モデルが拒否するため送らない |
