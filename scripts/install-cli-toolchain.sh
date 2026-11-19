#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared Fedora CLI toolchain for strict, usb and nested images.
# Additional arguments are profile-specific RPMs.
set -euo pipefail

packages=(
  # Essential shells, downloads and Git transport.
  bash
  fish
  ca-certificates
  curl
  wget
  openssl
  git
  openssh-clients

  # Standard UNIX tools, archives and text processing.
  coreutils
  findutils
  diffutils
  grep
  sed
  gawk
  which
  file
  less
  procps-ng
  util-linux
  tar
  gzip
  bzip2
  xz
  zstd
  zip
  unzip
  patch
  jq
  ripgrep

  # JavaScript/TypeScript: node, npm/npx, and Corepack (pnpm/yarn shims).
  # Do not also install the pnpm RPM: Corepack owns /usr/bin/pnpm.
  nodejs
  nodejs-npm
  nodejs-devel
  nodejs-corepack

  # Python: python3 -m venv, pip, virtualenv, pipx and uv.
  python3
  python3-pip
  python3-devel
  python3-virtualenv
  pipx
  uv

  # Rust and Go compilers / package managers.
  rust
  cargo
  golang

  # Minimal native-build prerequisites for Node/Python/Rust dependencies.
  gcc
  gcc-c++
  make
  cmake
  pkgconf-pkg-config
  openssl-devel
  libffi-devel
  zlib-devel
)

# Keep the original fail-closed security-update behavior. No third-party
# curl|sh installers or language package downloads run at image build time.
dnf -y upgrade --refresh
dnf -y --setopt=install_weak_deps=False install "${packages[@]}" "$@"
dnf clean all
rm -rf /var/cache/dnf

# Fail image builds if an RPM stops exposing a required CLI.
for binary in fish node npm npx corepack python3 pip3 virtualenv pipx uv rustc cargo go; do
  command -v "$binary" >/dev/null || {
    echo "Missing expected executable after RPM installation: $binary" >&2
    exit 1
  }
done
