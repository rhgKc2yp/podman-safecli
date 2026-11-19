#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Propose OBS fish RPM updates only when signed metadata has both architectures.

Run from the repository's scheduled GitHub Actions workflow. This script
updates tracked text files; a separate action opens/updates a reviewable PR.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "scripts/install-cli-toolchain.sh"
README = ROOT / "README.md"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
REPO = "https://download.opensuse.org/repositories/shells:/fish/Fedora_44"
REPO_NS = "{http://linux.duke.edu/metadata/repo}"
PKG_NS = "{http://linux.duke.edu/metadata/common}"
ARCHES = ("x86_64", "aarch64")
VERSION_PATTERN = r"[0-9]+(?:\.[0-9]+)+"
RELEASE_PATTERN = r"[0-9]+(?:\.[0-9]+)*"


class HttpsRedirectsOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise ValueError("Refusing a non-HTTPS OBS redirect")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(path: str, *, limit: int) -> bytes:
    if path.startswith("/") or ".." in path.split("/"):
        raise ValueError(f"Unsafe OBS path: {path}")
    opener = urllib.request.build_opener(HttpsRedirectsOnly())
    request = urllib.request.Request(
        f"{REPO}/{path}", headers={"User-Agent": "safecli-fish-update/1.0"}
    )
    with opener.open(request, timeout=30) as response:
        if urllib.parse.urlsplit(response.url).scheme != "https":
            raise ValueError("OBS response was not delivered over HTTPS")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Oversized OBS response: {path}")
    return data


def extract_setting(script: str, name: str, pattern: str) -> str:
    match = re.search(rf"(?m)^{re.escape(name)}='({pattern})'$", script)
    if not match or len(re.findall(rf"(?m)^{re.escape(name)}=", script)) != 1:
        raise ValueError(f"Expected a single {name} assignment in installer")
    return match.group(1)


def read_version(script: str) -> tuple[str, str]:
    return (
        extract_setting(script, "fish_version", VERSION_PATTERN),
        extract_setting(script, "fish_release", RELEASE_PATTERN),
    )


def pinned_key_sha256(script: str) -> str:
    match = re.search(r"'([0-9a-f]{64})' \"\$fish_key\"", script)
    if not match:
        raise ValueError("OBS signing key SHA-256 pin not found")
    return match.group(1)


def verify_signed_metadata(xml: bytes, signature: bytes, key: bytes) -> None:
    with tempfile.TemporaryDirectory(prefix="safecli-obs-") as directory:
        folder = Path(directory)
        (folder / "key.asc").write_bytes(key)
        (folder / "repomd.xml").write_bytes(xml)
        (folder / "repomd.xml.asc").write_bytes(signature)
        subprocess.run(
            ["gpg", "--batch", "--yes", "--dearmor", "--output", str(folder / "obs.gpg"),
             str(folder / "key.asc")],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["gpg", "--batch", "--no-default-keyring", "--keyring", str(folder / "obs.gpg"),
             "--verify", str(folder / "repomd.xml.asc"), str(folder / "repomd.xml")],
            check=True, capture_output=True,
        )


def primary_metadata(xml: bytes) -> tuple[str, str]:
    root = ET.fromstring(xml)
    for data in root.findall(f"{REPO_NS}data"):
        if data.get("type") != "primary":
            continue
        checksum = data.find(f"{REPO_NS}checksum")
        location = data.find(f"{REPO_NS}location")
        if checksum is None or location is None or checksum.get("type") != "sha256":
            raise ValueError("OBS primary metadata lacks a SHA-256 checksum")
        digest = (checksum.text or "").strip()
        path = location.get("href", "")
        if not re.fullmatch(r"repodata/[0-9a-f]{64}-primary\.xml\.gz", path):
            raise ValueError(f"Unexpected OBS primary metadata path: {path}")
        if digest not in path:
            raise ValueError("OBS primary metadata filename/checksum mismatch")
        return path, digest
    raise ValueError("OBS primary metadata missing")


def fish_packages(xml: bytes) -> tuple[str, str]:
    """Require an identical fish version/release for both target architectures."""
    root = ET.fromstring(xml)
    found: dict[str, tuple[str, str]] = {}
    for package in root.findall(f"{PKG_NS}package"):
        if package.findtext(f"{PKG_NS}name") != "fish":
            continue
        arch = package.findtext(f"{PKG_NS}arch")
        if arch not in ARCHES:
            continue
        version = package.find(f"{PKG_NS}version")
        location = package.find(f"{PKG_NS}location")
        if version is None or location is None or version.get("epoch") != "0":
            raise ValueError(f"Invalid fish RPM metadata for {arch}")
        ver, rel = version.get("ver", ""), version.get("rel", "")
        if not re.fullmatch(VERSION_PATTERN, ver) or not re.fullmatch(RELEASE_PATTERN, rel):
            raise ValueError(f"Unsupported fish RPM version/release: {ver}-{rel}")
        if location.get("href") != f"{arch}/fish-{ver}-{rel}.{arch}.rpm":
            raise ValueError(f"Unexpected fish RPM location for {arch}")
        if arch in found:
            raise ValueError(f"Ambiguous fish RPM metadata for {arch}")
        found[arch] = (ver, rel)
    if set(found) != set(ARCHES):
        raise ValueError("OBS fish RPMs are not published for both x86_64 and aarch64")
    if found[ARCHES[0]] != found[ARCHES[1]]:
        raise ValueError("OBS fish RPM versions differ between architectures")
    return found[ARCHES[0]]


def version_key(pair: tuple[str, str]) -> tuple[tuple[int, ...], tuple[int, ...]]:
    return tuple(int(piece) for piece in pair[0].split(".")), tuple(
        int(piece) for piece in pair[1].split(".")
    )


def replace_once(text: str, old: str, new: str, *, label: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one {label} reference; refusing partial update")
    return text.replace(old, new)


def plan_changes(current: tuple[str, str], latest: tuple[str, str]) -> dict[Path, str]:
    old_version, old_release = current
    new_version, new_release = latest
    script = INSTALLER.read_text()
    readme = README.read_text()
    notices = NOTICES.read_text()

    script = replace_once(script, f"fish_version='{old_version}'", f"fish_version='{new_version}'",
                          label="fish version setting")
    script = replace_once(script, f"fish_release='{old_release}'", f"fish_release='{new_release}'",
                          label="fish release setting")
    readme = replace_once(readme, f"fish **{old_version}**", f"fish **{new_version}**",
                          label="README fish version")
    readme = replace_once(readme, f"fish {old_version} RPM", f"fish {new_version} RPM",
                          label="README OBS fish RPM version")
    notices = replace_once(notices, f"**fish {old_version}**", f"**fish {new_version}**",
                           label="fish license notice")
    return {INSTALLER: script, README: readme, NOTICES: notices}


def main() -> None:
    script = INSTALLER.read_text()
    current = read_version(script)
    key = fetch("repodata/repomd.xml.key", limit=32 * 1024)
    if hashlib.sha256(key).hexdigest() != pinned_key_sha256(script):
        raise ValueError("OBS fish signing key changed; manual review required")
    repomd = fetch("repodata/repomd.xml", limit=1024 * 1024)
    signature = fetch("repodata/repomd.xml.asc", limit=32 * 1024)
    verify_signed_metadata(repomd, signature, key)

    primary_path, digest = primary_metadata(repomd)
    compressed = fetch(primary_path, limit=4 * 1024 * 1024)
    if hashlib.sha256(compressed).hexdigest() != digest:
        raise ValueError("OBS primary metadata checksum verification failed")
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        uncompressed = stream.read(16 * 1024 * 1024 + 1)
        if len(uncompressed) > 16 * 1024 * 1024:
            raise ValueError("OBS primary metadata decompressed to an oversized payload")
    latest = fish_packages(uncompressed)

    print(f"Installed fish: {current[0]}-{current[1]}; OBS fish: {latest[0]}-{latest[1]}")
    if version_key(latest) <= version_key(current):
        print("No newer common OBS fish RPM; nothing to propose.")
        return

    changes = plan_changes(current, latest)
    for path, content in changes.items():
        path.write_text(content)
        print(f"Updated {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
