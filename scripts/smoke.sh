#!/usr/bin/env bash
# smoke.sh <attr> <installed-prefix> <system>
#
# Use a built package the way a user would, beyond the package's own checks.
# <installed-prefix> is a store path or a Nix profile (anything with bin/).
# A package without a case here only gets the generic check.
set -euo pipefail

attr=$1 prefix=$2 system=$3
version=${VERSION:?VERSION is the package version}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

main=$(nix eval --raw --impure --file "${WORK:?}" "$attr.meta.mainProgram" 2>/dev/null || true)
if [[ -n "$main" ]]; then
  test -x "$prefix/bin/$main" || { echo "::error::$attr: $prefix/bin/$main is missing"; exit 1; }
fi

case "$attr" in
  gosti|io-mon|runquota)
    nix shell --impure --file "$WORK" python3 --command \
      python3 "$(dirname "$0")/check-tool-package.py" "$attr" "$prefix" "$system" "$version"
    ;;
  reprobuild)
    got=$("$prefix/bin/repro" --version)
    echo "repro --version: $got"
    [[ "$got" == "repro $version" ]] || { echo "::error::expected 'repro $version'"; exit 1; }

    # A real build: the C/Make example, with tools from PATH. The example
    # declares `gcc >=11`, which macOS's clang-as-gcc does not satisfy, so
    # this part runs on Linux.
    if [[ "$system" == *-linux ]]; then
      git clone -q --depth 1 https://github.com/metacraft-labs/reprobuild-examples "$tmp/examples"
      cp -r "$tmp/examples/c-cpp-make/binary" "$tmp/project"
      (
        cd "$tmp/project"
        export HOME="$tmp/home"
        mkdir -p "$HOME"
        "$prefix/bin/repro" build ".#default" --tool-provisioning=path
      )
      out=$(find "$tmp/project/.repro" -type f -name hello -perm -u+x | head -n1)
      [[ -n "$out" ]] || { echo "::error::repro build produced no hello executable"; exit 1; }
      greeting=$("$out")
      echo "built $out: $greeting"
      [[ "$greeting" == "hello from c-cpp-make-binary" ]] ||
        { echo "::error::unexpected output from the built example"; exit 1; }
    fi
    ;;
  codetracer)
    got=$("$prefix/bin/ct" version 2>&1 | tr -d '\033' | sed 's/\[[0-9;]*m//g') || true
    echo "ct version: $got"
    grep -q "CodeTracer version: $version" <<<"$got" ||
      { echo "::error::expected 'CodeTracer version: $version'"; exit 1; }
    ;;
esac
echo "smoke ok: $attr $version on $system"
