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

      nativeInstallCheckInputs = (previousAttrs.nativeInstallCheckInputs or [ ]) ++ [
        versionCheckHook
      ];
      doInstallCheck = true;

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
