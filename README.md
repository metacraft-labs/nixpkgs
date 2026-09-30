# metacraft-labs/nixpkgs

A fork of [NixOS/nixpkgs](https://github.com/NixOS/nixpkgs) that carries the
released packages of [Metacraft Labs](https://metacraft-labs.com) on top of
every popular upstream channel. For Nix users, this fork is the package
repository: there is nothing else to download.

This branch (`metacraft-ci`, the default) holds only this README and the
automation. The packages live on the channel branches below.

## Channels

Each channel branch is **named exactly after the upstream branch it tracks**,
and is that upstream branch plus our packages. Pick the one that matches the
nixpkgs you already use.

| Branch | Tracks upstream | Built and checked on | Status |
|---|---|---|---|
| [`nixos-unstable`](../../tree/nixos-unstable) | `nixos-unstable` | x86_64-linux | active |
| [`nixpkgs-unstable`](../../tree/nixpkgs-unstable) | `nixpkgs-unstable` | x86_64-linux, aarch64-darwin | active |
| [`nixos-26.05`](../../tree/nixos-26.05) | `nixos-26.05` | x86_64-linux | active |
| [`nixpkgs-26.05-darwin`](../../tree/nixpkgs-26.05-darwin) | `nixpkgs-26.05-darwin` | aarch64-darwin | active |

`channels.json` is the authoritative list. NixOS 25.11 and older are out of
upstream support, so no branch is kept for them.

## Packages

| Attribute | Version | Platforms | Upstream status |
|---|---|---|---|
| `reprobuild` (`repro`) | 0.2.5 | x86_64-linux, aarch64-darwin (checked); aarch64-linux, x86_64-darwin (declared) | not submitted: builds with a fork of the Nim compiler |
| `codetracer` (`ct`) | 25.11.1 | x86_64-linux | not submitted: prebuilt unfree binary |

Every package is on every channel branch, at the version of its latest stable
release. Each package's `package.nix` explains its upstreaming status.

## Installing

**NixOS with flakes** (use the branch named like your system's `nixpkgs`):

```nix
{
  inputs.metacraft.url = "github:metacraft-labs/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, metacraft, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            metacraft.legacyPackages.${pkgs.stdenv.hostPlatform.system}.reprobuild
          ];
        })
      ];
    };
  };
}
```

Updates arrive with `nix flake update metacraft` and `nixos-rebuild switch`.

**NixOS with channels:**

```sh
sudo nix-channel --add https://github.com/metacraft-labs/nixpkgs/archive/nixos-26.05.tar.gz metacraft
sudo nix-channel --update metacraft
```

```nix
# /etc/nixos/configuration.nix
{ pkgs, ... }:
let metacraft = import <metacraft> { inherit (pkgs.stdenv.hostPlatform) system; };
in { environment.systemPackages = [ metacraft.reprobuild ]; }
```

Updates arrive with `nixos-rebuild switch --upgrade`.

**Nix on any other Linux, or macOS:**

```sh
nix profile install github:metacraft-labs/nixpkgs/nixpkgs-unstable#reprobuild
nix profile upgrade --all     # later, to update
```

`codetracer` is unfree: set `nixpkgs.config.allowUnfree = true`, or
`NIXPKGS_ALLOW_UNFREE=1` together with `--impure` on the command line. It runs
its AppImage inside bubblewrap, which needs unprivileged user namespaces; on
Ubuntu 24.04 and later these are restricted by AppArmor
(`kernel.apparmor_restrict_unprivileged_userns`).

There is no binary cache for these branches yet: the first install builds
`reprobuild` and its Nim compiler from source (about 15 minutes on 4 cores).

Never install from a product repository's own flake at `dev`: that is
unreleased code under a release's name.

## How the fork works

### One source of truth: the `metacraft` branch

[`metacraft`](../../tree/metacraft) is upstream `nixos-unstable` plus **one
clean commit series**: the commits that add or update our packages, and
nothing else. It may only touch `pkgs/by-name/`; the automation refuses to run
otherwise. The series is exactly what `metacraft` has that upstream `master`
does not (their merge base is where it starts), so no marker commit or
separate base ref is needed.

Every channel branch is **generated** from it: the series rebased onto that
upstream channel. Nobody commits to a channel branch directly; a commit there
is overwritten by the next sync.

Why a rebased series and not merges or a patch directory:

- **The delta stays reviewable.** `git log upstream/nixos-unstable..metacraft`
  is our whole difference from upstream, one commit per change, in the form
  an upstream PR takes. Merges would bury it under upstream history.
- **It is a real nixpkgs tree.** Packages are developed and tested with the
  ordinary tools (`nix build .#reprobuild`), which a patch directory kept
  outside the tree would not allow.
- **One series, many channels.** Carrying packages per channel branch is how
  the delta drifts apart; generating every channel from one series cannot.

### The automation

[`.github/workflows/sync-channels.yml`](.github/workflows/sync-channels.yml)
runs **daily at 04:23 UTC** and on demand. For each channel in
`channels.json`, independently
([`sync-channel.yml`](.github/workflows/sync-channel.yml)):

1. **rebase** the series onto the upstream channel head. A conflict fails
   the channel.
2. **build** every package the series touches, on each system the channel
   serves (GitHub-hosted `ubuntu-latest` and `macos-latest`). A package whose
   `meta.platforms` excludes a system is skipped there. The packages' own
   checks run as part of the build (`reprobuild` checks that `repro
   --version` reports the packaged version), and then
   [`scripts/smoke.sh`](scripts/smoke.sh) uses each package: on Linux,
   `repro build` builds and runs a C/Make example project.
3. **publish** only if every build of that channel is green: force-push the
   channel branch, with a lease on the tip the run started from. **A broken
   rebase or build never replaces a working branch.** Each published revision
   is also kept under `refs/archive/<channel>/<timestamp>`, so the revision a
   user's `flake.lock` names stays fetchable after the branch moves on.

4. **verify** the published branch the way a user installs from it:
   `nix build github:metacraft-labs/nixpkgs/<channel>#<package>`, then
   `nix profile install` into a throwaway profile and the same smoke test.
   A failure here cannot un-publish, so it opens the channel's issue.

After `nixos-unstable` publishes, `metacraft` itself is moved onto the same
upstream commit (again with a lease, so a push made during the run wins).
Pull it with `git pull --rebase`.

A channel whose rebase or build fails **opens an issue** labelled
[`upstream-sync`](../../issues?q=label%3Aupstream-sync), titled
`Channel sync failed: <channel>`; later failures comment on it, and the next
successful publish closes it. A new upstream NixOS release that
`channels.json` does not list opens `New NixOS release: nixos-YY.MM`.

`scripts/sync.sh` holds every step, so a run can be reproduced locally:

```sh
scripts/sync.sh plan                     # prints series_base, series_len, series_head
export SERIES_BASE=… SERIES_LEN=… SERIES_HEAD=…
scripts/sync.sh rebase nixos-26.05       # prints upstream_sha, result_sha
export UPSTREAM_SHA=… RESULT_SHA=…
scripts/sync.sh checkout && scripts/sync.sh build x86_64-linux   # tree in /tmp/nixpkgs
```

Channel pushes use a write deploy key of this repository (secret
`CHANNEL_PUSH_KEY`). The workflow's own `GITHUB_TOKEN` cannot be used: GitHub
refuses a token-authenticated push whose commits change `.github/workflows/`,
and every rebase onto a newer upstream carries upstream's workflow changes.

## Maintaining packages

**Releasing a new version** is part of the release (a release is not done
while a NixOS user cannot get it):

```sh
git clone --depth=20 --branch metacraft https://github.com/metacraft-labs/nixpkgs
cd nixpkgs
pkgs/by-name/re/reprobuild/update.sh 0.2.6     # or: codetracer/update.sh 26.09.1
nix build .#reprobuild && ./result/bin/repro --version
git commit -am 'reprobuild: 0.2.5 -> 0.2.6'
git push origin metacraft
gh workflow run sync-channels.yml -R metacraft-labs/nixpkgs   # don't wait for the daily run
```

Each package directory has an `update.sh` (also its `passthru.updateScript`).
Run without a version, it takes the latest published GitHub release.
`reprobuild/update.sh` copies the release's own build recipe verbatim from
the tag and regenerates `pins.json` from the tag's `flake.lock`. If a release
adds a source input the package does not pass yet, it stops and says so.

**Adding a package:** add `pkgs/by-name/<xx>/<name>/package.nix` to
`metacraft` in its own commit (`<name>: init at <version>`), with a comment
saying why it is not upstream yet (see below). The next sync carries it to
every channel.

## Upstreaming: the fork is a waiting room

When a package is accepted into upstream nixpkgs, **it is removed from this
fork** in the same change that moves the channels past the upstream commit
carrying it, so no user sees it disappear before it reappears. In practice the
rebase then conflicts (both sides add the same file) and the sync opens an
issue: drop the package's commits from `metacraft` and re-run the workflow.

Every package here is therefore one of:

1. waiting on an open upstream PR (linked in its `package.nix`);
2. genuinely unsuitable for upstream (the reason is in its `package.nix`);
3. a bug in this process, if it is neither.

## Adding and retiring channels

A new NixOS release (`nixos-YY.MM` with its `nixpkgs-YY.MM-darwin`) is added
to `channels.json` with `"status": "active"`; the next run creates both
branches. When upstream stops supporting a release, set its entries to
`"status": "deprecated"`: the branch is no longer synced, and is **not
deleted**, because a user's `flake.lock` may still name it. List it in the
table above as deprecated.

## Other branches

- `master`: an old, unmaintained mirror of upstream `master`. Not synced.
- `metacraft-labs-packages-2026-06-04`, `reprobuild-m4`: frozen snapshots
  from before the channel branches existed, kept because lock files may name
  them. Use a channel branch instead.
