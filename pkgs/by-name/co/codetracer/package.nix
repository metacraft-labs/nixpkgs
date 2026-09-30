# CodeTracer, a time-travelling debugger, packaged from its released AppImage.
#
# CodeTracer publishes a versioned AppImage for every release at
# downloads.codetracer.com/CodeTracer-<version>-amd64.AppImage (the GitHub
# release only carries a `resources.tar.xz` companion). This package wraps that
# AppImage; it does not build CodeTracer from source, whose build spans a Nim,
# Rust and Electron toolchain plus private components.
#
# To update: `pkgs/by-name/co/codetracer/update.sh [VERSION]`.
#
# Upstreaming status (the fork is a waiting room, see the fork's README): not
# submitted. The package redistributes a prebuilt binary with closed-source
# components; it would be acceptable upstream as an unfree binary package, and
# should be submitted once CodeTracer publishes release checksums.
{
  lib,
  fetchurl,
  appimageTools,
  bpftrace,
}:

let
  pname = "codetracer";
  version = "25.11.1";

  src = fetchurl {
    url = "https://downloads.codetracer.com/CodeTracer-${version}-amd64.AppImage";
    hash = "sha256-2qEEE++G0SMkTR1Y4e+d9CVEkDoUrLxS38/D23IXrrs=";
  };

  extracted = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    # Desktop entry and icons from the AppImage, pointed at the wrapped binary.
    install -Dm644 ${extracted}/codetracer.desktop \
      $out/share/applications/codetracer.desktop
    substituteInPlace $out/share/applications/codetracer.desktop \
      --replace-fail "Exec=ct" "Exec=$out/bin/ct"
    if [ -d ${extracted}/usr/share/icons ]; then
      mkdir -p $out/share
      cp -r ${extracted}/usr/share/icons $out/share/
    fi

    # `ct` is the command users expect.
    ln -s $out/bin/codetracer $out/bin/ct

    # bpftrace for BPF-based process monitoring. It needs cap_bpf, cap_perfmon
    # and cap_dac_read_search: grant them with a NixOS `security.wrappers`
    # entry, `setcap` on other systems, or CodeTracer's `ct install --bpf`.
    mkdir -p $out/libexec
    cp ${bpftrace}/bin/bpftrace $out/libexec/codetracer-bpftrace
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Time-travelling debugger for many programming languages";
    homepage = "https://codetracer.com";
    downloadPage = "https://downloads.codetracer.com";
    changelog = "https://github.com/metacraft-labs/codetracer/releases/tag/${version}";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "ct";
  };
}
