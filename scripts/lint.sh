#!/usr/bin/env bash
# Fails if any Swift source is not formatted or breaks a swift-format lint rule. Fix with scripts/format.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swift format lint --strict --recursive --parallel Package.swift Sources Tests scripts/make-icons.swift \
  scripts/check-localization.swift
# Every Japanese UI string needs an English translation in Resources/en.lproj/Localizable.strings.
swift scripts/check-localization.swift .
