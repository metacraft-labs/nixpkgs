#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p python3
"""Refresh release pins from a published version and its SHA256SUMS.

No source rebuilds. Preserve the reviewed platform set, reject conflicting
checksums and changes to an already pinned version. Write only after every
archive has downloaded and matched the release checksum manifest.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request

root = Path(__file__).resolve().parent
app = root.name
current = json.loads((root / "release.json").read_text())
repository = f"metacraft-labs/{app}"


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "metacraft-release-pins"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


version = sys.argv[1] if len(sys.argv) == 2 else json.loads(
    get(f"https://api.github.com/repos/{repository}/releases/latest")
)["tag_name"].removeprefix("v")
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("expected a stable MAJOR.MINOR.PATCH release")
if tuple(map(int, version.split("."))) < tuple(map(int, current["version"].split("."))):
    raise SystemExit("refusing to move a maintained channel to an older release")
base = f"https://github.com/{repository}/releases/download/v{version}"
sums = {}
for line in get(base + "/SHA256SUMS").decode().splitlines():
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
    if match:
        sums.setdefault(match[2], set()).add(match[1].lower())
updated = {"version": version, "platforms": {}}
for system in current["platforms"]:
    target = {"x86_64-linux": "linux-x86_64", "aarch64-darwin": "darwin-aarch64"}[system]
    name = f"{app}-{version}-{target}.tar.gz"
    url = f"{base}/{name}"
    digest = hashlib.sha256(get(url)).digest()
    if sums.get(name) != {digest.hex()}:
        raise SystemExit(f"{name}: missing, conflicting or incorrect release checksum")
    updated["platforms"][system] = {
        "url": url, "hash": "sha256-" + base64.b64encode(digest).decode()
    }
if version == current["version"] and updated != current:
    raise SystemExit("refusing changed bytes for an already pinned release")
(root / "release.json").write_text(json.dumps(updated, indent=2, sort_keys=True) + "\n")
print(f"{app}: pinned verified {version} archives on {', '.join(updated['platforms'])}")
