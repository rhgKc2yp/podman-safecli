#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify all three profiles consistently use Fedora stable latest and Fedora package names.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for profile in strict usb nested; do
  file="Containerfile.$profile"
  [[ -f "$file" ]]
  grep -Fqx 'FROM docker.io/library/fedora:latest' "$file"
  grep -Fq 'dnf -y --setopt=install_weak_deps=False install' "$file"
  grep -Fq 'dnf clean all' "$file"
  if grep -Eq 'apt-get|DEBIAN_FRONTEND|debian:|libusb-1.0-0' "$file"; then
    echo "Unexpected Debian instructions in $file" >&2
    exit 1
  fi
done
grep -Eq 'usbutils.*|libusb1' Containerfile.usb
grep -Fq 'libusb1' Containerfile.usb
grep -Fq 'bubblewrap' Containerfile.nested
grep -Fq 'util-linux' Containerfile.nested

echo 'All Fedora stable latest Containerfile checks passed.'
