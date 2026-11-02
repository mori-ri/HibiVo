English | [日本語](../building.md)

# Build from source

If you just want to use HibiVo, install the app from [Releases](https://github.com/mori-ri/HibiVo/releases/latest). This page is for people who want to build it on their own Mac or work on it.

## Requirements

- The macOS 26 SDK: Xcode 26 or later, or Command Line Tools (`xcode-select --install`) that include the macOS 26 SDK

The app you build runs on macOS 14 or later.

## Build and install

```sh
git clone https://github.com/mori-ri/HibiVo.git
cd HibiVo
scripts/create-signing-cert.sh          # optional, recommended (see below)
CONFIG=release scripts/build-app.sh      # creates build/HibiVo.app
mv build/HibiVo.app /Applications/
open /Applications/HibiVo.app
```

An app you build yourself is not marked as "downloaded", so Gatekeeper does not warn about it.
Placing the app in `/Applications` enables "Launch at Login".

If `/Applications` already has a HibiVo.app, `mv` fails and `open` launches the old app. Replace it with the steps in [Updating](#updating) instead.

For what to do after launching it, see [First-time setup](../../README.en.md#first-time-setup).

## Signing certificate

Run `scripts/create-signing-cert.sh` once and the Accessibility permission survives rebuilds (you will be asked for your password to set the certificate's trust).
If your keychain has a "Developer ID Application" certificate, it is used instead, with the hardened runtime.
With neither certificate the permission is lost on every build, so run `tccutil reset Accessibility io.github.mori-ri.hibivo` and grant it again.

## Updating

```sh
git pull
CONFIG=release scripts/build-app.sh && {
  pkill -x HibiVo
  rm -rf /Applications/HibiVo.app
  mv build/HibiVo.app /Applications/
  open /Applications/HibiVo.app
}
```

If the build succeeds, this quits the running HibiVo, replaces it, and starts the new one. If it fails, the installed app stays as it is.

## Switching between your build and the released app

Switching between a HibiVo you built yourself and the app from Releases, in either direction, means granting Accessibility, Microphone, and Keychain access once more.

## Development

```sh
scripts/run.sh        # debug build and launch
scripts/test.sh       # tests
scripts/format.sh     # format the code
scripts/lint.sh       # check formatting and translations (also run in CI)
```

To change the icon, replace `Resources/AppIconSource.png` and run `swift scripts/make-icons.swift`.

There is no Xcode project. The app is built with SwiftPM, and `scripts/build-app.sh` assembles and signs the `.app`.
With only the Command Line Tools installed, the build automatically uses `MacOSX26.sdk` if it is there (in the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode). Without it the build fails with "plugin for module 'SwiftUIMacros' not found".

UI strings are written in Japanese in the code and translated in `Resources/en.lproj/Localizable.strings`. `swift scripts/check-localization.swift` checks that every Japanese UI string has a translation.
