#!/usr/bin/env python3
"""Check a real Nix install against its published archive and exercise its CLI.

No mocks: download the archive/checksum manifest, compare every installed file
and symlink, compile a native child, and run real io-mon capture or a RunQuota
client/daemon lease. Gosti's explicit noop backend exercises command dispatch
without allocating a VM; product CI separately qualifies the hypervisors.
Called both before channel publication and after `nix profile install`.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("product", choices=["gosti", "io-mon", "runquota"])
parser.add_argument("prefix", type=Path)
parser.add_argument("system", choices=["x86_64-linux", "aarch64-darwin"])
parser.add_argument("version")
args = parser.parse_args()
assert re.fullmatch(r"\d+\.\d+\.\d+", args.version)
expected_host = {"x86_64-linux": ("Linux", "x86_64"), "aarch64-darwin": ("Darwin", "arm64")}[args.system]
assert (platform.system(), platform.machine()) == expected_host, "native host required"
target = {"x86_64-linux": "linux-x86_64", "aarch64-darwin": "darwin-aarch64"}[args.system]
app = args.product
stem = f"{app}-{args.version}-{target}"
base = f"https://github.com/metacraft-labs/{app}/releases/download/v{args.version}"
prefix = args.prefix.resolve()
payload = prefix / "libexec" / app


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "metacraft-channel-verification"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def command(*argv, expected=0, **kwargs):
    result = subprocess.run([str(a) for a in argv], text=True, capture_output=True,
                            timeout=45, **kwargs)
    assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
    return result.stdout


with tempfile.TemporaryDirectory(prefix="mcl-nix-") as directory:
    work = Path(directory).resolve()
    archive = work / f"{stem}.tar.gz"
    archive.write_bytes(download(f"{base}/{archive.name}"))
    expected_sums = set()
    for line in download(base + "/SHA256SUMS").decode().splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
        if match and match[2] == archive.name:
            expected_sums.add(match[1].lower())
    assert expected_sums == {hashlib.sha256(archive.read_bytes()).hexdigest()}, "release checksum mismatch"
    members = set()
    with tarfile.open(archive) as release:
        for member in release:
            relative = PurePosixPath(member.name).relative_to(stem)
            assert not relative.is_absolute() and ".." not in relative.parts
            if member.isdir():
                continue
            key = relative.as_posix()
            assert key not in members, f"duplicate member: {key}"
            members.add(key)
            installed = payload / key
            if member.issym():
                assert installed.is_symlink() and os.readlink(installed) == member.linkname, key
            else:
                assert member.isfile() and installed.is_file() and not installed.is_symlink(), key
                original = release.extractfile(member).read()
                assert hashlib.sha256(installed.read_bytes()).digest() == hashlib.sha256(original).digest(), key
                if member.mode & 0o111:
                    assert os.access(installed, os.X_OK), key
    observed = {p.relative_to(payload).as_posix() for p in payload.rglob("*")
                if p.is_file() or p.is_symlink()}
    assert observed == members and members, (observed - members, members - observed)
    print(f"PASS: {app} {args.version}: {len(members)} payload files/links match release", flush=True)

    bins = {name: prefix / "bin" / name for name in {
        "gosti": ["gosti", "vm-harness"], "io-mon": ["io-mon"],
        "runquota": ["runquota", "runquotad"]
    }[app]}
    for path in bins.values():
        assert path.is_symlink() and os.access(path, os.X_OK), path
        if args.system == "aarch64-darwin":
            assert path.resolve() == (payload / "bin" / path.name).resolve()
    env = dict(os.environ, XDG_STATE_HOME=str(work / "state"),
               XDG_CONFIG_HOME=str(work / "config"), XDG_CACHE_HOME=str(work / "cache"))
    if app == "gosti":
        for binary in bins.values():
            assert "provision" in command(binary, "--help", env=env, cwd=work)
            assert "noop" in command(binary, "backends", env=env, cwd=work)
            command(binary, "provision", "--backend", "noop", "--guest", "linux",
                    "--baseline", "release-smoke", env=env, cwd=work)
            command(binary, "ephemeral-list", "--backend", "noop", env=env, cwd=work)
        assert (payload / "share/vm-harness/guest-recipes").is_dir()
    else:
        # A native binary avoids platform-protected system tools on macOS and
        # proves the FHS runtime can execute a caller's own binary on Linux.
        source = work / "child.c"
        source.write_text('''#include <stdio.h>
int main(int argc, char **argv) {
  if (argc == 1) { puts("release-lease-ok"); return 7; }
  if (argc != 3) return 20;
  FILE *in = fopen(argv[1], "rb"), *out = fopen(argv[2], "wb");
  if (!in || !out) return 21;
  int c; while ((c = fgetc(in)) != EOF) fputc(c, out);
  fputs("-captured", out); fclose(in); fclose(out); return 7;
}
''')
        child = work / "child"
        command(shutil.which("cc") or "cc", source, "-o", child)
        assert "release-lease-ok" in command(child, expected=7)
        if app == "io-mon":
            incoming, outgoing, depfile = work / "input.txt", work / "output.txt", work / "capture.rdep"
            incoming.write_text("release-input")
            command(child, incoming, work / "control.txt", expected=7)
            assert (work / "control.txt").read_text() == "release-input-captured"
            command(bins[app], "run", "--depfile", depfile, "--", child, incoming, outgoing,
                    expected=7, env=env, cwd=work)
            assert outgoing.read_text() == "release-input-captured"
            decoded = command(bins[app], "inspect", depfile, "--format", "json", env=env)
            report = json.loads(decoded)
            assert report["completeness"] == "mcComplete", decoded
            assert report["summary"]["eventLossCount"] == 0, decoded
            assert str(incoming) in decoded and str(outgoing) in decoded, decoded
        else:
            for name, binary in bins.items():
                assert command(binary, "--version", env=env).strip() == f"{name} {args.version}"
            endpoint = work / "daemon.sock"
            env["RUNQUOTA_SOCKET"] = str(endpoint)
            with (work / "daemon.log").open("w+") as log:
                daemon = subprocess.Popen([str(bins["runquotad"]), "--socket", str(endpoint),
                    "--cpu-milli", "2000", "--memory-bytes", "268435456",
                    "--memory-pressure-source", "unavailable", "--no-write-stats",
                    "--estimate-db", str(work / "estimates"), "--observation-db", str(work / "observations"),
                    "--host-identity-file", str(work / "host")], env=env, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 20
                    while True:
                        if daemon.poll() is not None:
                            log.seek(0)
                            raise AssertionError(f"daemon exited: {log.read()}")
                        try:
                            json.loads(command(bins[app], "status", "--json", env=env))
                            break
                        except (AssertionError, json.JSONDecodeError):
                            assert time.monotonic() < deadline, "daemon readiness deadline"
                            time.sleep(0.1)
                    leased = command(bins[app], "acquire", "--cpu", "1", "--mem", "16777216",
                                     "--", child, expected=7, env=env)
                    assert "release-lease-ok" in leased, leased
                    json.loads(command(bins[app], "leases", "--json", env=env))
                finally:
                    daemon.terminate()
                    try:
                        code = daemon.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait()
                        raise AssertionError("daemon did not terminate")
                    assert code in (0, -signal.SIGTERM), f"daemon shutdown: {code}"
    print(f"PASS: {app} {args.version}: installed commands on {args.system}", flush=True)
