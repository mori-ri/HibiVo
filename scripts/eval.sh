#!/usr/bin/env bash
# Runs the cleanup quality eval (Sources/HibiVoEval). Calls real LLM providers and a Claude judge,
# so it costs money and is never part of scripts/test.sh. Results go to .claude/hillclimb/cleanup/.
#
#   scripts/eval.sh --variant baseline --provider anthropic --model claude-haiku-4-5
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift build --product HibiVoEval >/dev/null
exec "$(swift build --show-bin-path)/HibiVoEval" "$@"
