# Reprobuild, a reproducible build system with automatic dependency discovery.
#
# This package builds a published release of metacraft-labs/reprobuild with the
# build recipe that release itself ships. The files in this directory are:
#
#   package.nix   this entry point: pins every source from ./pins.json and
#                 calls the recipe, exactly as reprobuild's own flake does;
#   reprobuild.nix, nim-fork.nix
#                 the recipe, copied verbatim from the release tag
#                 (nix/pkgs/by-name/re/reprobuild/ in reprobuild);
#   pins.json     the release tag and every source it builds from, taken from
#                 the tag's flake.lock, with fixed-output hashes;
#   update.sh     regenerates the three files above for a release.
#
# To update: `pkgs/by-name/re/reprobuild/update.sh [VERSION]`, then build.
#
# Upstreaming status (the fork is a waiting room, see the fork's README): not
# submitted. Reprobuild builds with a from-source fork of the Nim compiler
# (metacraft-labs/nim, Nim 2.3.1 devel; see ./nim-fork.nix for why stock Nim
# cannot be used), and nixpkgs does not accept a package that bootstraps its
# own compiler. It can be submitted once that fork's changes are in a released
# Nim, or the fork is packaged as a Nim variant in its own right.
{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  versionCheckHook,
}:

let
  pins = lib.importJSON ./pins.json;

  fetchPin =
    pin:
    fetchFromGitHub {
      inherit (pin)
        owner
        repo
        rev
        hash
        ;
      fetchSubmodules = pin.fetchSubmodules or false;
    };

  nimFork = callPackage ./nim-fork.nix (lib.mapAttrs (_: fetchPin) pins.nimForkSources);
in
(callPackage ./reprobuild.nix (
  {
    inherit nimFork;
  }
  // lib.mapAttrs (_: fetchPin) pins.sources
)).overrideAttrs
  (
    finalAttrs: previousAttrs: {
      inherit (pins) version;

      src = fetchFromGitHub {
        owner = "metacraft-labs";
        repo = "reprobuild";
        tag = "v${finalAttrs.version}";
        inherit (pins.src) hash;
      };

      # librepro_monitor_shim.so is LD_PRELOADed into every process a build
      # runs, including the host's own compilers under
      # `--tool-provisioning=path`, so it must load against the host's glibc.
      # nixpkgs' cc-wrapper defaults x86 Linux to `-mtls-dialect=gnu2`, which
      # makes the shim require GLIBC_ABI_GNU2_TLS (glibc 2.40+): on an older
      # host (Ubuntu 24.04 has 2.39) every build action then fails to start.
      # The traditional dialect works with every glibc; a later flag wins.
      env =
        previousAttrs.env
        // lib.optionalAttrs (stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86) {
          NIX_CFLAGS_COMPILE = toString [
            (previousAttrs.env.NIX_CFLAGS_COMPILE or "")
            "-mtls-dialect=gnu"
          ];
        };

      # Recipes (the project's reprobuild.nim) are compiled into helper
      # binaries that link this package's runtime libraries, which are built
      # against nixpkgs' glibc. Compiled with the host's own C compiler, as
      # happens on a non-NixOS Linux, they would link the host's older glibc
      # and fail to load those libraries. REPRO_BOOTSTRAP_CC selects the
      # compiler for recipe compiles only (package actions still use the
      # tools the project asks for), so default it to the matching one.
      postFixup =
        let
          anchor = "--set-default REPRO_NIM_COMPILER";
        in
        if !stdenv.hostPlatform.isLinux then
          previousAttrs.postFixup
        else if lib.hasInfix anchor previousAttrs.postFixup then
          lib.replaceStrings
            [ anchor ]
            [
              "--set-default REPRO_BOOTSTRAP_CC ${stdenv.cc}/bin/cc ${anchor}"
            ]
            previousAttrs.postFixup
        else
          throw "reprobuild: the recipe's wrapProgram call changed; re-check the REPRO_BOOTSTRAP_CC default in package.nix";

      nativeInstallCheckInputs = (previousAttrs.nativeInstallCheckInputs or [ ]) ++ [
        versionCheckHook
      ];
      doInstallCheck = true;
      postInstallCheck = lib.optionalString stdenv.hostPlatform.isLinux ''
        shim="$out/lib/librepro_monitor_shim.so"
        test -e "$shim"
        if grep -q GLIBC_ABI_GNU2_TLS "$shim"; then
          echo "$shim requires GLIBC_ABI_GNU2_TLS; it would not load on hosts older than glibc 2.40" >&2
          exit 1
        fi
        grep -q "REPRO_BOOTSTRAP_CC" "$out/bin/repro"
      '';

      passthru = previousAttrs.passthru // {
        updateScript = ./update.sh;
      };

      meta = previousAttrs.meta // {
        description = "Reproducible build system with automatic dependency discovery";
        longDescription = ''
          Reprobuild observes the processes a build runs to discover its real
          inputs and outputs, caches every action by content, and rebuilds
          only what changed. It installs the `repro` command.
        '';
        homepage = "https://github.com/metacraft-labs/reprobuild";
        changelog = "https://github.com/metacraft-labs/reprobuild/releases/tag/v${finalAttrs.version}";
        license = lib.licenses.asl20;
        mainProgram = "repro";
        maintainers = [ ];
      };
    }
  )
