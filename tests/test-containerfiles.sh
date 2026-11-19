#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify all three profiles use the same Fedora CLI package set.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

toolchain=scripts/install-cli-toolchain.sh
bash -n "$toolchain"

for profile in strict usb nested; do
  file="Containerfile.$profile"
  [[ -f "$file" ]]
  grep -Fqx 'FROM docker.io/library/fedora:latest' "$file"
  grep -Fq 'COPY scripts/install-cli-toolchain.sh /tmp/install-cli-toolchain.sh' "$file"
  grep -Fq 'RUN bash /tmp/install-cli-toolchain.sh' "$file"
  grep -Fq 'SHELL=/usr/bin/fish' "$file"
  grep -Fq 'NPM_CONFIG_PREFIX=/work/.npm-global' "$file"
  grep -Fq 'CARGO_HOME=/work/.cargo' "$file"
  grep -Fq 'GOPATH=/work/go' "$file"
  grep -Fq 'GOBIN=/work/go/bin' "$file"
  grep -Fq '/work/.npm-global/bin:/work/.local/bin:/work/.cargo/bin:/work/go/bin' "$file"
  grep -Fqx 'CMD ["/usr/bin/fish"]' "$file"
  if grep -Eq 'apt-get|DEBIAN_FRONTEND|debian:|libusb-1.0-0' "$file"; then
    echo "Unexpected Debian instructions in $file" >&2
    exit 1
  fi
done

for rpm in \
  fish nano nodejs nodejs-npm nodejs-corepack python3 python3-pip \
  python3-virtualenv pipx uv rust cargo golang curl wget unzip \
  gcc gcc-c++ make pkgconf-pkg-config; do
  grep -Fqx "  $rpm" "$toolchain"
done

for excluded_rpm in gh ruby ruby-devel rubygems rubygem-bundler php-cli perl lua \
                    java-25-openjdk-headless clang git-lfs; do
  if grep -Fqx "  $excluded_rpm" "$toolchain"; then
    echo "Nonessential RPM unexpectedly included: $excluded_rpm" >&2
    exit 1
  fi
done

# Fedora Corepack already ships pnpm and yarn shims; don't overwrite them.
if grep -Eq '^[[:space:]]+pnpm[[:space:]]*$' "$toolchain"; then
  echo 'Do not install pnpm alongside nodejs-corepack.' >&2
  exit 1
fi

grep -Fqx '!scripts/install-cli-toolchain.sh' .dockerignore
grep -Fq 'usbutils' Containerfile.usb
grep -Fq 'libusb1' Containerfile.usb
grep -Fq 'libusb1-devel' Containerfile.usb
grep -Fq 'bubblewrap' Containerfile.nested
grep -Fqx '  util-linux' "$toolchain"

echo 'All Fedora CLI toolchain and Containerfile checks passed.'
