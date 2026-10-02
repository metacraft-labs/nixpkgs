# Release binaries are kept byte-for-byte: Package Distribution sections 4/14.
# Linux uses the existing FHS runtime instead of patching ELF files. macOS
# preserves the release's ad-hoc signatures. Native release platform scope
# intentionally excludes the deferred Linux ARM64 and Intel macOS ports.
# Upstream submission follows qualification of these initial binary recipes;
# tracked in metacraft-pm's tool release distribution conformance issue.
{
  lib,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  runCommand,
}:
let
  pname = "gosti";
  release = lib.importJSON ./release.json;
  inherit (release) version;
  platform =
    release.platforms.${stdenvNoCC.hostPlatform.system}
      or (throw "${pname}: no published payload for ${stdenvNoCC.hostPlatform.system}");
  src = fetchurl { inherit (platform) url hash; };
  commands = [
    "gosti"
    "vm-harness"
  ];
  payload = stdenvNoCC.mkDerivation {
    pname = "${pname}-release-payload";
    inherit version src;
    phases = [
      "unpackPhase"
      "installPhase"
    ];
    # Includes script shebangs, executable signatures, bundled libraries/data.
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec/${pname}"
      cp -a . "$out/libexec/${pname}/"
      diff -r --no-dereference . "$out/libexec/${pname}"
      runHook postInstall
    '';
  };
  commandPath =
    command:
    if stdenvNoCC.hostPlatform.isLinux then
      let
        runtime = buildFHSEnv {
          pname = "${pname}-${command}-runtime";
          inherit version;
          executableName = command;
          targetPkgs = pkgs: [ pkgs.glibc ];
          multiPkgs = _: [ ];
          runScript = "${payload}/libexec/${pname}/bin/${command}";
          # Daemon sockets, resource accounting and VM backends use host state.
          privateTmp = false;
          unsharePid = false;
          unshareIpc = false;
          unshareNet = false;
        };
      in
      "${runtime}/bin/${command}"
    else
      "${payload}/libexec/${pname}/bin/${command}";
in
runCommand "${pname}-${version}"
  {
    inherit pname version;
    passthru = {
      inherit payload;
      releaseArchive = src;
      updateScript = ./update.py;
    };
    meta = {
      description = "Create and manage virtual machine guests";
      homepage = "https://github.com/metacraft-labs/${pname}";
      changelog = "https://github.com/metacraft-labs/${pname}/releases/tag/v${version}";
      license = lib.licenses.asl20;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      mainProgram = pname;
      platforms = builtins.attrNames release.platforms;
      maintainers = [ ];
    };
  }
  ''
    mkdir -p "$out/bin"
    ln -s ${payload}/libexec "$out/libexec"
    ${lib.concatMapStringsSep "\n" (command: ''
      ln -s ${commandPath command} "$out/bin/${command}"
    '') commands}
  ''
