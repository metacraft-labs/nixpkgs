#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils curl jq git nix gnused
# shellcheck shell=bash
#
# Update the reprobuild package to a published release.
#
#   pkgs/by-name/re/reprobuild/update.sh            # latest GitHub release
#   pkgs/by-name/re/reprobuild/update.sh 0.2.6      # a specific release
#
# Also reachable as `passthru.updateScript` (nixpkgs' maintainers/scripts/update.nix).
#
# What it does, all from the release tag of metacraft-labs/reprobuild:
#   1. copies nix/pkgs/by-name/re/reprobuild/{package,nim-fork}.nix verbatim
#      to ./reprobuild.nix and ./nim-fork.nix (the build recipe the release
#      itself was built with);
#   2. regenerates ./pins.json from the tag's flake.lock: every source input
#      the recipe takes, with its rev and a fixed-output hash computed for
#      `fetchFromGitHub`, plus the tag's own rev and hash.
#
# It fails loudly (and changes nothing) when the tag's flake.lock grows a
# `*-src` input that pins.json does not map to a recipe argument: that means
# the recipe gained a dependency, and ./package.nix must pass it through.
set -euo pipefail

owner=metacraft-labs
repo=reprobuild
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pins="$here/pins.json"
nixcmd=(nix --extra-experimental-features "nix-command flakes")

gh_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl -fsSL "${auth[@]}" "https://api.github.com/$1"
}

version="${1:-${UPDATE_NIX_NEW_VERSION:-}}"
if [[ -z "$version" ]]; then
  version=$(gh_api "repos/$owner/$repo/releases/latest" | jq -r .tag_name)
fi
version="${version#v}"
tag="v$version"

old_version=$(jq -r .version "$pins")
echo "reprobuild: $old_version -> $version ($tag)" >&2

rev=$(git ls-remote "https://github.com/$owner/$repo" "refs/tags/$tag^{}" | cut -f1)
if [[ -z "$rev" ]]; then
  rev=$(git ls-remote "https://github.com/$owner/$repo" "refs/tags/$tag" | cut -f1)
fi
[[ -n "$rev" ]] || { echo "tag $tag not found in $owner/$repo" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
raw="https://raw.githubusercontent.com/$owner/$repo/$rev"
curl -fsSL "$raw/flake.lock" -o "$work/flake.lock"
curl -fsSL "$raw/nix/pkgs/by-name/re/reprobuild/package.nix" -o "$work/reprobuild.nix"
curl -fsSL "$raw/nix/pkgs/by-name/re/reprobuild/nim-fork.nix" -o "$work/nim-fork.nix"
curl -fsSL "$raw/reprobuild.nimble" -o "$work/reprobuild.nimble"

nimble_version=$(sed -n 's/^version *= *"\(.*\)".*/\1/p' "$work/reprobuild.nimble")
if [[ "$nimble_version" != "$version" ]]; then
  echo "$tag carries reprobuild.nimble version $nimble_version, not $version" >&2
  exit 1
fi

# Every `*-src` root input of the tag's lock must be mapped in pins.json.
jq -r '.nodes.root.inputs | keys[] | select(endswith("-src"))' "$work/flake.lock" |
  sort >"$work/lock-inputs"
jq -r '[.sources[], .nimForkSources[]] | .[].input' "$pins" | sort >"$work/mapped-inputs"
unmapped=$(comm -23 "$work/lock-inputs" "$work/mapped-inputs")
if [[ -n "$unmapped" ]]; then
  echo "error: $tag's flake.lock has source inputs that pins.json does not map:" >&2
  echo "$unmapped" | sed 's/^/  /' >&2
  echo "Add each to pins.json (sources or nimForkSources) with the recipe argument" >&2
  echo "that reprobuild's flake.nix passes it as, and pass it through in package.nix." >&2
  exit 1
fi

# prefetch <owner> <repo> <rev> <submodules:true|false> -> SRI hash that
# fetchFromGitHub produces for the same arguments.
prefetch() {
  local url
  if [[ "$4" == true ]]; then
    url="git+https://github.com/$1/$2?rev=$3&submodules=1"
  else
    url="github:$1/$2/$3"
  fi
  "${nixcmd[@]}" flake prefetch --json "$url" | jq -r .hash
}

resolve() { # <section> -> rewritten section JSON on stdout
  local section=$1 name input node type url o r rev_ sub hash locked_hash
  local out='{}'
  for name in $(jq -r ".$section | keys[]" "$pins"); do
    input=$(jq -r ".$section[\"$name\"].input" "$pins")
    sub=$(jq -r ".$section[\"$name\"].fetchSubmodules // false" "$pins")
    node=$(jq -r --arg i "$input" '.nodes.root.inputs[$i]' "$work/flake.lock")
    type=$(jq -r --arg n "$node" '.nodes[$n].locked.type' "$work/flake.lock")
    rev_=$(jq -r --arg n "$node" '.nodes[$n].locked.rev' "$work/flake.lock")
    case "$type" in
      github)
        o=$(jq -r --arg n "$node" '.nodes[$n].locked.owner' "$work/flake.lock")
        r=$(jq -r --arg n "$node" '.nodes[$n].locked.repo' "$work/flake.lock")
        ;;
      git)
        url=$(jq -r --arg n "$node" '.nodes[$n].locked.url' "$work/flake.lock")
        url="${url%.git}"
        [[ "$url" == https://github.com/* ]] || { echo "$input: not a GitHub source ($url)" >&2; exit 1; }
        o=$(cut -d/ -f4 <<<"$url")
        r=$(cut -d/ -f5 <<<"$url")
        ;;
      *) echo "$input: unsupported lock type $type" >&2; exit 1 ;;
    esac
    hash=$(prefetch "$o" "$r" "$rev_" "$sub")
    locked_hash=$(jq -r --arg n "$node" '.nodes[$n].locked.narHash // empty' "$work/flake.lock")
    if [[ -n "$locked_hash" && "$locked_hash" != "$hash" ]]; then
      echo "note: $input: fetchFromGitHub hash $hash differs from lock narHash $locked_hash" >&2
    fi
    echo "  $name <- $o/$r@${rev_:0:12}" >&2
    out=$(jq --arg k "$name" --arg i "$input" --arg o "$o" --arg r "$r" \
      --arg rev "$rev_" --arg h "$hash" --argjson s "$sub" \
      '.[$k] = ({input: $i, owner: $o, repo: $r, rev: $rev, hash: $h}
                + (if $s then {fetchSubmodules: true} else {} end))' <<<"$out")
  done
  echo "$out"
}

src_hash=$(prefetch "$owner" "$repo" "$rev" false)
sources=$(resolve sources)
nim_sources=$(resolve nimForkSources)

jq -n --arg v "$version" --arg rev "$rev" --arg h "$src_hash" \
  --argjson s "$sources" --argjson n "$nim_sources" \
  '{version: $v, src: {owner: "metacraft-labs", repo: "reprobuild", rev: $rev, hash: $h},
    sources: $s, nimForkSources: $n}' >"$work/pins.json"

header() {
  cat <<EOF
# Synced verbatim from metacraft-labs/reprobuild $tag ($rev)
#   nix/pkgs/by-name/re/reprobuild/$1
# by ./update.sh. Do not edit here: change it in reprobuild, release, re-run
# ./update.sh. The default source arguments below are not used by this
# package; ./package.nix passes every one of them from ./pins.json.

EOF
}
{ header package.nix; cat "$work/reprobuild.nix"; } >"$here/reprobuild.nix"
{ header nim-fork.nix; cat "$work/nim-fork.nix"; } >"$here/nim-fork.nix"
cp "$work/pins.json" "$pins"
echo "reprobuild: updated to $version" >&2
