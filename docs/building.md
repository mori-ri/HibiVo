[English](en/building.md) | 日本語

# ソースからビルド

普段使うだけなら、[Releases](https://github.com/mori-ri/HibiVo/releases/latest) のアプリをインストールしてください。このページは、自分の Mac でビルドしたい人や、開発に参加したい人向けです。

## 必要なもの

- macOS 14 以降
- Command Line Tools（`xcode-select --install`）または Xcode

## ビルドしてインストール

```sh
git clone https://github.com/mori-ri/HibiVo.git
cd HibiVo
scripts/create-signing-cert.sh          # 任意・推奨（下記）
CONFIG=release scripts/build-app.sh      # build/HibiVo.app を作成
mv build/HibiVo.app /Applications/
open /Applications/HibiVo.app
```

自分でビルドしたアプリには「ダウンロードしたもの」の印が付かないため、Gatekeeper の警告は出ません。
`/Applications` に置くと「ログイン時に起動」が使えます。

起動したあとの設定は [初回セットアップ](../README.md#初回セットアップ) を参照してください。

## 署名証明書

`scripts/create-signing-cert.sh` を一度実行しておくと、再ビルドしてもアクセシビリティの許可が保たれます（信頼設定のためにパスワードを求められます）。
実行しない場合はビルドのたびに許可が外れるので、`tccutil reset Accessibility io.github.mori-ri.hibivo` を実行して許可し直してください。

## アップデート

```sh
git pull
CONFIG=release scripts/build-app.sh
rm -rf /Applications/HibiVo.app && mv build/HibiVo.app /Applications/
```

## 配布版に切り替える

自分でビルドした HibiVo から Releases のアプリに切り替えると、アクセシビリティとマイクの許可、Keychain のアクセス許可を一度だけ許可し直す必要があります。

## 開発

```sh
scripts/run.sh        # デバッグビルドして起動
scripts/test.sh       # テスト
```

アイコンを変更したときは `Resources/AppIconSource.png` を差し替えて `swift scripts/make-icons.swift` を実行します。

Xcode プロジェクトはありません。SwiftPM でビルドし、`scripts/build-app.sh` が `.app` を組み立てて署名します。
Command Line Tools だけの環境では、自動的に macOS 26 SDK でビルドします（macOS 27 SDK では SwiftUI の `@State` がマクロになり、そのプラグインが Xcode にしか含まれていないため）。

UI の文字列はコードに日本語で書き、英訳は `Resources/en.lproj/Localizable.strings` に書きます。`swift scripts/check-localization.swift` で、日本語の文字列すべてに英訳があるかを確認できます。
