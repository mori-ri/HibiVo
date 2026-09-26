#!/usr/bin/env bash
# Rebuilds and relaunches HibiVo.app.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x HibiVo 2>/dev/null || true
CONFIG="${CONFIG:-debug}" scripts/build-app.sh
open build/HibiVo.app
