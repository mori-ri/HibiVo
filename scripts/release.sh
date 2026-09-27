#!/usr/bin/env bash
# Cuts a HibiVo release in two steps.
#
#   scripts/release.sh prepare <version>   Bump Resources/Info.plist (version, build number +1).
#                                          From main: commits on a new release-v<version> branch and opens a PR.
#                                          From release/*: commits and pushes on that branch directly.
#   scripts/release.sh publish             Tag the current Info.plist version at HEAD (main or release/*),
#                                          push the tag and create a draft GitHub release with generated notes.
#
# Typical flow: prepare -> merge the PR -> switch to an up-to-date main -> publish -> edit the draft and publish it.
# Versions follow SemVer; a pre-release suffix (e.g. 0.4.0-beta.1) marks the GitHub release as a pre-release.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plist_get_at() { git show "$1:$PLIST" | plutil -extract "$2" raw -o - -; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"; }

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == [yY] ]]
}

require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] || die "作業ツリーに未コミットの変更があります。"
}

require_tag_absent() {
  local tag="$1"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || [[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; then
    die "タグ $tag は既に存在します。"
  fi
}

current_branch() { git symbolic-ref --short -q HEAD || true; }

# Highest CFBundleVersion among the working copy and every v* tag. Patches cut on release/* branches never
# bump main's Info.plist, so looking only at the working copy would hand out a build number twice.
max_released_build() {
  local max="$1" tag build
  for tag in $(git tag --list 'v*'); do
    build="$(git show "$tag:$PLIST" 2>/dev/null | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
    if [[ "$build" =~ ^[0-9]+$ ]] && ((build > max)); then
      max="$build"
    fi
  done
  echo "$max"
}

prepare() {
  local version="${1:-}"
  [[ -n "$version" ]] || usage
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "バージョンの形式が不正です: $version (例: 0.3.0, 0.4.0-beta.1)"

  require_clean_tree
  git fetch -q origin --tags
  require_tag_absent "v$version"

  local branch base_branch base_ref
  branch="$(current_branch)"
  if [[ "$branch" == release/* ]]; then
    base_branch=""
    base_ref=HEAD
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null)" ]] \
      || die "$branch が origin/$branch と一致しません。pull または push してから実行してください。"
  else
    base_branch=main
    base_ref=origin/main
    branch="release-v$version"
  fi

  # Read the version from the commit the bump will be based on, not the working copy (which may be a stale
  # local main or an unrelated branch), so the "already at" check and the build number reflect origin/main.
  local old_version old_build new_build
  old_version="$(plist_get_at "$base_ref" CFBundleShortVersionString)"
  old_build="$(plist_get_at "$base_ref" CFBundleVersion)"
  [[ "$old_build" =~ ^[0-9]+$ ]] || die "CFBundleVersion が整数ではありません: $old_build"
  [[ "$version" != "$old_version" ]] || die "Info.plist は既に $version です。"
  new_build=$(($(max_released_build "$old_build") + 1))

  if [[ -n "$base_branch" ]]; then
    git switch -c "$branch" "$base_ref"
  fi

  plist_set CFBundleShortVersionString "$version"
  plist_set CFBundleVersion "$new_build"
  git add "$PLIST"
  git commit -q -m "Bump version to $version (build $new_build)"
  echo "Info.plist: $old_version ($old_build) -> $version ($new_build)"

  git push -q -u origin "$branch"
  if [[ -n "$base_branch" ]]; then
    gh pr create --base "$base_branch" --head "$branch" --title "Release v$version" \
      --body "HibiVo v$version のリリース準備として、バージョンを $version (build $new_build) に上げます。

マージ後、最新の main で \`scripts/release.sh publish\` を実行してタグとリリースの下書きを作ります。"
    echo "PR をマージしたら: git switch main && git pull && scripts/release.sh publish"
  else
    echo "続けて: scripts/release.sh publish"
  fi
}

publish() {
  [[ $# -eq 0 ]] || usage
  require_clean_tree
  git fetch -q origin --tags

  local branch
  branch="$(current_branch)"
  [[ "$branch" == main || "$branch" == release/* ]] || die "main か release/* ブランチで実行してください (現在: ${branch:-detached HEAD})。"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null)" ]] \
    || die "$branch が origin/$branch と一致しません。pull または push してから実行してください。"

  local version tag build head
  version="$(plist_get CFBundleShortVersionString)"
  build="$(plist_get CFBundleVersion)"
  tag="v$version"
  head="$(git rev-parse HEAD)"
  require_tag_absent "$tag"

  # CI only runs on pushes to main and on PRs, so release/* commits may have no run; ask instead of failing.
  local ci
  ci="$(gh run list --workflow ci.yml --commit "$head" --json conclusion --jq 'map(.conclusion) | join(",")')"
  if [[ ",$ci," != *,success,* ]]; then
    echo "警告: ${head:0:7} の CI 成功が確認できません (結果: ${ci:-なし})。"
    confirm "それでも続行しますか?" || exit 1
  fi

  # Notes start from the last tag reachable from HEAD, so a patch on release/* doesn't shift main's next notes.
  local notes_args=(--generate-notes)
  local prev_tag
  if prev_tag="$(git describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null)"; then
    notes_args+=(--notes-start-tag "$prev_tag")
  fi
  local release_args=(--draft --verify-tag --title "HibiVo $tag")
  if [[ "$version" == *-* ]]; then
    release_args+=(--prerelease)
  fi

  echo "$branch の ${head:0:7} に $tag (build $build) を打ち、リリースの下書きを作ります (前回: ${prev_tag:-なし})。"
  git log -20 --oneline --no-decorate ${prev_tag:+"$prev_tag..HEAD"}
  confirm "タグを push しますか?" || exit 1

  git tag -a "$tag" -m "HibiVo $tag"
  git push -q origin "$tag"
  gh release create "$tag" "${release_args[@]}" "${notes_args[@]}" \
    || die "タグ $tag は push 済みですが、リリースの作成に失敗しました。次のコマンドを手動で実行してください: $(printf "%q " gh release create "$tag" "${release_args[@]}" "${notes_args[@]}")"
  echo "下書きを作成しました。自動生成されたノートをユーザー向けの日本語に書き直してから公開してください。"
}

case "${1:-}" in
  prepare) shift; prepare "$@" ;;
  publish) shift; publish "$@" ;;
  *) usage ;;
esac
