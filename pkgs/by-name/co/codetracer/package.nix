{
  lib,
  fetchurl,
  appimageTools,
  bpftrace,
}:

let
  pname = "codetracer";

  # CodeTracer is a closed-source binary distribution; upstream ships a
  # single "latest" AppImage at a stable URL rather than per-tag GitHub
  # release assets (the github.com/metacraft-labs/codetracer releases
  # only publish a `resources.tar.xz` companion archive, not the
  # AppImage itself). We therefore version by the upload date of the
  # AppImage at fetch time.
  #
  # To refresh: re-run
  #   nix-prefetch-url --type sha256 \
  #     https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage
  # then bump both `version` (to today's date) and `hash` below.
  version = "unstable-2026-02-04";

  src = fetchurl {
    url = "https://downloads.codetracer.com/CodeTracer-latest-amd64.AppImage";
    hash = "sha256-uAEZqtDD4tcKH8gpbbsuid/99NWBv85g0pWM+ddUaiA=";
  };

  extracted = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  extraInstallCommands = ''
    # Install desktop file and icons from the extracted AppImage.
    install -Dm644 ${extracted}/codetracer.desktop \
      $out/share/applications/codetracer.desktop

    # Fix Exec path in the desktop file to point to the Nix store binary.
    substituteInPlace $out/share/applications/codetracer.desktop \
      --replace "Exec=ct edit %F" "Exec=$out/bin/codetracer edit %F"

    # Create the ct symlink that users expect.
    ln -s $out/bin/codetracer $out/bin/ct

    # Bundle bpftrace for capabilities-based BPF process monitoring.
    # On NixOS, the (out-of-tree) programs.codetracer module wires up a
    # security.wrappers entry with cap_bpf,cap_perfmon,cap_dac_read_search.
    # On non-NixOS systems, users can manually `setcap` this binary or
    # rely on the in-product `ct install --bpf` flow.
    mkdir -p $out/libexec
    cp ${bpftrace}/bin/bpftrace $out/libexec/codetracer-bpftrace
  '';

  meta = {
    description = "Record/replay debugger with CI integration and BPF process monitoring";
    homepage = "https://codetracer.com";
    license = lib.licenses.unfree;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "ct";
  };
}
