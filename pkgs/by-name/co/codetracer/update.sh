#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils curl jq nix gnused
# shellcheck shell=bash
#
# Update the codetracer package to a published release.
#
#   pkgs/by-name/co/codetracer/update.sh            # latest GitHub release
#   pkgs/by-name/co/codetracer/update.sh 26.09.1    # a specific release
#
# Only a published (non-draft) GitHub release counts as a release: the
# versioned AppImage can exist on downloads.codetracer.com before its release
# is published.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pkg="$here/package.nix"

gh_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl -fsSL "${auth[@]}" "https://api.github.com/$1"
}

version="${1:-${UPDATE_NIX_NEW_VERSION:-}}"
if [[ -z "$version" ]]; then
  version=$(gh_api "repos/metacraft-labs/codetracer/releases/latest" | jq -r .tag_name)
fi
version="${version#v}"
gh_api "repos/metacraft-labs/codetracer/releases/tags/$version" |
  jq -e '.draft == false' >/dev/null ||
  { echo "codetracer $version is not a published release" >&2; exit 1; }

url="https://downloads.codetracer.com/CodeTracer-$version-amd64.AppImage"
hash=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri \
  "$(nix-prefetch-url --type sha256 "$url")")

sed -i \
  -e "s|^  version = \".*\";|  version = \"$version\";|" \
  -e "s|^    hash = \"sha256-.*\";|    hash = \"$hash\";|" \
  "$pkg"
echo "codetracer: updated to $version ($hash)" >&2
