#!/usr/bin/env bash
# Formats Swift sources in place with swift-format (bundled with the toolchain). Config: .swift-format.
set -euo pipefail
cd "$(dirname "$0")/.."
swift format format --in-place --recursive --parallel Package.swift Sources Tests scripts/make-icons.swift \
  scripts/check-localization.swift
