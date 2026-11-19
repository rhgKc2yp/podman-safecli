#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Static regression checks for the security-update path and publishing cadence.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for profile in strict usb nested; do
  file="Containerfile.$profile"
  grep -Fqx 'FROM docker.io/library/fedora:latest' "$file"
  grep -Fq 'COPY scripts/install-cli-toolchain.sh /tmp/install-cli-toolchain.sh' "$file"
done
grep -Fq 'dnf -y upgrade --refresh' scripts/install-cli-toolchain.sh
grep -Fq 'dnf -y --setopt=install_weak_deps=False install' scripts/install-cli-toolchain.sh
grep -Fq 'dnf clean all' scripts/install-cli-toolchain.sh

wf=.github/workflows/publish-ghcr.yml
grep -Fq -- "- cron: '23 4 */3 * *'" "$wf"
grep -Fq 'pull: true' "$wf"
grep -Fq 'no-cache: true' "$wf"
grep -Fq 'uses: actions/checkout@v7' "$wf"
grep -Fq 'uses: actions/upload-artifact@v7' "$wf"
grep -Fq 'uses: actions/download-artifact@v8' "$wf"
grep -Fq 'uses: actions/attest@v4' "$wf"
grep -Fq 'sbom: true' "$wf"
grep -Fq 'run: bash scripts/generate-sboms.sh' "$wf"
grep -Fq 'sbom-path: sboms/amd64.attest.spdx.json' "$wf"
grep -Fq 'sbom-path: sboms/arm64.attest.spdx.json' "$wf"
grep -Fq -- '--platform "linux/$arch"' scripts/generate-sboms.sh
grep -Fq -- '--select-catalogers=-file' scripts/generate-sboms.sh
grep -Fq -- '--select-catalogers=rpm' scripts/generate-sboms.sh
grep -Fq 'cosign sign --yes' "$wf"
grep -Fq 'bash scripts/promote-image.sh' "$wf"

# Prevent accidental reintroduction of a pinned Fedora EOL target.
if grep -ERq 'FROM docker.io/library/fedora:[0-9]+' Containerfile.*; then
  echo 'ERROR: Fedora base images must track stable latest.' >&2
  exit 1
fi

# Verify the root license text and separate treatment of upstream software.
grep -Fq 'MIT License' LICENSE
grep -Fq 'Copyright (c) 2026' LICENSE
grep -Fq 'upstream' THIRD_PARTY_NOTICES.md

echo 'Fedora latest update and four supply-chain safeguard checks passed.'
