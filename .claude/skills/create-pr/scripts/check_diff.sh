#!/usr/bin/env bash
# Scans everything that would go into the PR (commits since BASE plus staged and
# unstaged changes) for files that must not be published and for strings that look
# like credentials. Exits 1 when anything is found so the caller stops before pushing.
#
# Usage: check_diff.sh [BASE]   (default BASE: origin/main)
set -uo pipefail

base="${1:-origin/main}"
status=0

files=$(
  {
    git diff --name-only "$base"...HEAD
    git diff --name-only --cached
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sort -u
)

# Local-only notes, build products, env/secret files, signing material, editor junk.
forbidden_paths='^(notes/|build/|\.build/|\.swiftpm/)|(^|/)\.env(\..*)?$|\.secret$|(^|/)\.DS_Store$|\.(p12|pem|key|cer|mobileprovision|keychain)$|xcuserdata/'
bad_files=$(printf '%s\n' "$files" | grep -E "$forbidden_paths" || true)
if [ -n "$bad_files" ]; then
  echo "== Files that must not be in the PR =="
  printf '%s\n' "$bad_files"
  status=1
fi

# Added lines only; the "+++" header lines are dropped.
added=$(
  {
    git diff -U0 "$base"...HEAD
    git diff -U0 --cached
    git diff -U0
  } | grep '^+' | grep -v '^+++' || true
)

# Anthropic, OpenAI-style, AWS access key IDs, Bedrock API keys, PEM private keys,
# Soniox-style long hex keys assigned to a variable, and generic secret assignments.
secret_patterns='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{32,}|(AKIA|ASIA)[0-9A-Z]{16}|ABSK[A-Za-z0-9+/=]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(api[_-]?key|secret[_-]?access[_-]?key|password|token)["'"'"' ]*[:=] *["'"'"'][A-Za-z0-9+/_-]{24,}["'"'"']'
hits=$(printf '%s\n' "$added" | grep -inE "$secret_patterns" || true)
if [ -n "$hits" ]; then
  echo "== Added lines that look like credentials (check whether they are real) =="
  printf '%s\n' "$hits" | cut -c1-200
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "OK: no forbidden files or credential-like strings found."
fi
exit "$status"
