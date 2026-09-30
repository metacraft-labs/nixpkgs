#!/usr/bin/env bash
# Channel sync for metacraft-labs/nixpkgs. Driven by
# .github/workflows/sync-channels.yml; every step of that workflow is one
# subcommand here, so a run can be reproduced locally step by step.
#
#   sync.sh plan                 find the carried series, emit the channel matrix
#   sync.sh rebase  <channel>    rebase the series onto upstream <channel>
#   sync.sh checkout             materialise the rebased tree from the bundle
#   sync.sh build   <system>     build every carried package available on <system>
#   sync.sh publish <channel>    push the rebased tree to <channel>
#
# The carried series is the commits of the `metacraft` branch that are not in
# upstream NixOS/nixpkgs (see README.md). It may only touch pkgs/by-name/.
set -euo pipefail

FORK="${FORK:-metacraft-labs/nixpkgs}"
UPSTREAM="${UPSTREAM:-NixOS/nixpkgs}"
CONFIG="${CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels.json}"
WORK="${WORK:-${RUNNER_TEMP:-/tmp}/nixpkgs}"
BUNDLE="${BUNDLE:-${RUNNER_TEMP:-/tmp}/series.bundle}"
SERIES_BRANCH=$(jq -r .series "$CONFIG")

out() { # key=value to the step outputs (or stdout outside Actions)
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >>"$GITHUB_OUTPUT"; fi
  echo "output: $1" >&2
}
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >&2; fi; }
die() { echo "::error::$*" >&2; exit 1; }

git_in() { git -C "$WORK" "$@"; }

init_work() {
  rm -rf "$WORK"
  git init -q "$WORK"
  git_in config user.name "metacraft-labs channel sync"
  git_in config user.email "channel-sync@metacraft-labs.com"
  git_in config advice.detachedHead false
  git_in remote add origin "https://github.com/$FORK.git"
  git_in remote add upstream "https://github.com/$UPSTREAM.git"
}

# ---------------------------------------------------------------------------
cmd_plan() {
  local compare base len head files bad
  # The series is exactly what `metacraft` has that upstream master does not.
  # Channel heads are all commits of upstream master or of a release branch
  # forked from it, so this merge base is where the series starts.
  compare=$(gh api "repos/$UPSTREAM/compare/master...${FORK%%/*}:${FORK##*/}:$SERIES_BRANCH")
  base=$(jq -r .merge_base_commit.sha <<<"$compare")
  len=$(jq -r .ahead_by <<<"$compare")
  head=$(gh api "repos/$FORK/branches/$SERIES_BRANCH" --jq .commit.sha)
  [[ "$len" -gt 0 ]] || die "$SERIES_BRANCH carries no commits over upstream"
  [[ "$len" -le 250 ]] || die "$SERIES_BRANCH is $len commits ahead; the compare API lists at most 250"

  files=$(jq -r '.files[].filename' <<<"$compare")
  bad=$(grep -v '^pkgs/by-name/' <<<"$files" || true)
  if [[ -n "$bad" ]]; then
    die "$SERIES_BRANCH touches files outside pkgs/by-name/: $(tr '\n' ' ' <<<"$bad")"
  fi

  out "series_base=$base"
  out "series_len=$len"
  out "series_head=$head"

  local filter="${CHANNELS:-}" matrix
  matrix=$(jq -c --arg f "$filter" '
      [.channels[]
        | select(.status == "active")
        | select($f == "" or (.name | IN($f | split(",") | map(gsub("^ +| +$"; ""))[])))
        | .name]' "$CONFIG")
  [[ "$matrix" != "[]" ]] || die "no active channel matches '${filter}'"
  out "channels=$matrix"

  # A NixOS release upstream that we do not track yet is somebody's job to add.
  local known upstream_releases missing=()
  known=$(jq -r '.channels[].name' "$CONFIG")
  upstream_releases=$(git ls-remote --heads "https://github.com/$UPSTREAM.git" 'nixos-[0-9]*' |
    sed -n 's|.*refs/heads/\(nixos-[0-9][0-9]\.[0-9][0-9]\)$|\1|p' | sort -V | tail -1)
  for r in $upstream_releases; do
    grep -qx "$r" <<<"$known" || missing+=("$r")
  done
  out "untracked_release=${missing[*]:-}"

  {
    echo "### Carried series"
    echo
    echo "\`$SERIES_BRANCH\` @ \`${head:0:12}\`: $len commit(s) on upstream \`${base:0:12}\`"
    echo
    echo '```'
    echo "$files"
    echo '```'
    echo
    echo "Channels: \`$matrix\`"
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo
      echo "**Upstream has ${missing[*]}, which channels.json does not list.**"
    fi
  } | summary
}

# ---------------------------------------------------------------------------
cmd_rebase() {
  local channel=$1
  : "${SERIES_BASE:?}" "${SERIES_LEN:?}" "${SERIES_HEAD:?}"
  init_work
  git_in fetch -q --no-tags --depth=1 upstream "+refs/heads/$channel:refs/remotes/upstream/$channel"
  git_in fetch -q --no-tags --depth=$((SERIES_LEN + 1)) origin "$SERIES_HEAD"
  local upstream_sha
  upstream_sha=$(git_in rev-parse "refs/remotes/upstream/$channel")

  [[ "$(git_in rev-parse "$SERIES_HEAD~$SERIES_LEN")" == "$SERIES_BASE" ]] ||
    die "$SERIES_BRANCH~$SERIES_LEN is not the merge base $SERIES_BASE; did $SERIES_BRANCH move?"

  git_in checkout -q -B result "$SERIES_HEAD"
  if ! git_in rebase -q --onto "$upstream_sha" "$SERIES_BASE" result 2>"$WORK.rebase.log"; then
    local conflicted
    conflicted=$(git_in diff --name-only --diff-filter=U || true)
    {
      echo "### Rebase of \`$SERIES_BRANCH\` onto upstream \`$channel\` conflicts"
      echo
      echo "Upstream \`$channel\` @ \`$upstream_sha\`."
      echo
      echo "Conflicting files:"
      echo '```'
      echo "${conflicted:-<none listed>}"
      echo '```'
      echo '```'
      tail -n 40 "$WORK.rebase.log"
      echo '```'
      echo
      echo "If upstream now carries one of these packages, it has been accepted"
      echo "upstream: drop its commits from \`$SERIES_BRANCH\` (README, \"Upstreaming\")."
    } | tee "${RUNNER_TEMP:-/tmp}/failure.md" | summary
    git_in rebase --abort || true
    out "stage=conflict"
    die "rebase onto upstream $channel conflicts: ${conflicted:-see log}"
  fi
  local result_sha
  result_sha=$(git_in rev-parse result)

  # What the channel branch holds now, and whether this run would change it.
  local old_sha changed=true
  old_sha=$(git ls-remote "https://github.com/$FORK.git" "refs/heads/$channel" | cut -f1)
  if [[ -n "$old_sha" ]]; then
    if git_in fetch -q --no-tags --depth=$((SERIES_LEN + 1)) origin "$old_sha" 2>/dev/null &&
      [[ "$(git_in rev-parse "$old_sha~$SERIES_LEN" 2>/dev/null)" == "$upstream_sha" ]] &&
      [[ "$(git_in rev-parse "$old_sha^{tree}")" == "$(git_in rev-parse "result^{tree}")" ]]; then
      changed=false
    fi
  fi

  git_in bundle create -q "$BUNDLE" refs/heads/result "^$upstream_sha"
  out "upstream_sha=$upstream_sha"
  out "result_sha=$result_sha"
  out "old_sha=$old_sha"
  out "changed=$changed"
  {
    echo "### \`$channel\`"
    echo
    echo "- upstream: \`$upstream_sha\`"
    echo "- rebased:  \`$result_sha\`"
    echo "- current:  \`${old_sha:-<branch does not exist>}\`"
    echo "- changed:  $changed"
  } | summary
}

# ---------------------------------------------------------------------------
cmd_checkout() {
  : "${UPSTREAM_SHA:?}" "${RESULT_SHA:?}"
  init_work
  git_in fetch -q --no-tags --depth=1 upstream "$UPSTREAM_SHA"
  git_in bundle verify -q "$BUNDLE"
  git_in fetch -q "$BUNDLE" "refs/heads/result:refs/heads/result"
  [[ "$(git_in rev-parse result)" == "$RESULT_SHA" ]] || die "bundle does not hold $RESULT_SHA"
  git_in checkout -q result
}

carried_packages() { # attribute names of the pkgs/by-name directories the series touches
  git_in diff --name-only "$UPSTREAM_SHA" result -- pkgs/by-name |
    sed -n 's|^pkgs/by-name/[^/]*/\([^/]*\)/.*|\1|p' | sort -u
}

# ---------------------------------------------------------------------------
cmd_build() {
  local system=$1 attr available failed=() built=()
  : "${UPSTREAM_SHA:?}"
  export NIXPKGS_ALLOW_UNFREE=1
  cd "$WORK"
  for attr in $(carried_packages); do
    available=$(nix eval --impure --raw --expr "
      let pkgs = import ./. { system = \"$system\"; };
          p = pkgs.$attr;
      in if pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform p && !(p.meta.broken or false)
         then \"yes\" else \"no\"")
    if [[ "$available" != yes ]]; then
      echo "::notice::$attr is not available on $system; skipped"
      continue
    fi
    echo "::group::nix build $attr ($system)"
    if nix build --impure -L --file . "$attr" --out-link "result-$attr"; then
      built+=("$attr=$(readlink "result-$attr")")
    else
      failed+=("$attr")
    fi
    echo "::endgroup::"
  done
  {
    echo "### Build on \`$system\`"
    for b in ${built[@]+"${built[@]}"}; do echo "- ok: \`${b%%=*}\` → \`${b#*=}\`"; done
    for f in ${failed[@]+"${failed[@]}"}; do echo "- **failed: \`$f\`**"; done
  } | summary
  if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'Build failed on %s: %s\n' "$system" "${failed[*]}" >"${RUNNER_TEMP:-/tmp}/failure.md"
    die "build failed on $system: ${failed[*]}"
  fi
}

# ---------------------------------------------------------------------------
cmd_publish() {
  local channel=$1
  : "${RESULT_SHA:?}" "${SERIES_HEAD:?}"
  local old="${OLD_SHA:-}" tracks
  tracks=$(jq -r .seriesTracks "$CONFIG")
  git_in remote set-url --push origin "git@github.com:$FORK.git"
  # --force-with-lease against the tip this run started from: if anything else
  # moved the branch in the meantime, do not overwrite it.
  # Channel branches are rewritten, but a user's flake.lock names a revision:
  # keep every published revision reachable under refs/archive/, which is not
  # a branch or tag and so stays out of listings.
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  git_in push --atomic origin \
    --force-with-lease="refs/heads/$channel:$old" \
    "$RESULT_SHA:refs/heads/$channel" \
    "$RESULT_SHA:refs/archive/$channel/$stamp"
  echo "published $channel = $RESULT_SHA (archived as refs/archive/$channel/$stamp)" | summary

  # The series branch itself follows the channel it tracks, so it never falls
  # far behind upstream. A human push since the run started wins.
  if [[ "$channel" == "$tracks" ]]; then
    if git_in push --force-with-lease="refs/heads/$SERIES_BRANCH:$SERIES_HEAD" origin \
      "$RESULT_SHA:refs/heads/$SERIES_BRANCH"; then
      echo "moved $SERIES_BRANCH onto upstream $channel" | summary
    else
      echo "::warning::$SERIES_BRANCH moved during the run; left as is"
    fi
  fi
}

case "${1:-}" in
  plan) cmd_plan ;;
  rebase) cmd_rebase "$2" ;;
  checkout) cmd_checkout ;;
  build) cmd_build "$2" ;;
  publish) cmd_publish "$2" ;;
  *) die "usage: $0 plan|rebase <channel>|checkout|build <system>|publish <channel>" ;;
esac
