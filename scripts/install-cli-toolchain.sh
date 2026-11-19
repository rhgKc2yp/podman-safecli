#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared Fedora CLI toolchain for strict, usb and nested images.
# Additional arguments are profile-specific RPMs.
set -euo pipefail

packages=(
  # Essential shells, downloads and Git transport.
  bash
  nano
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

  # Fedora's unversioned nodejs/nodejs-npm still select Node 22/npm 10.
  # Explicit -bin packages expose Node 26 and its Fedora-matched npm 11 as node/npm.
  # Do not install pnpm separately: Corepack owns /usr/bin/pnpm.
  nodejs26
  nodejs26-bin
  nodejs26-npm-bin
  nodejs26-devel
  nodejs-corepack

  # Python: expose both python and python3 for Python 3, plus venv and pip.
  python3
  python-unversioned-command
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

# Keep the original fail-closed Fedora security-update behavior.
dnf -y upgrade --refresh
dnf -y --setopt=install_weak_deps=False install "${packages[@]}" "$@"

# Opt in to Fedora 45 updates-testing only for the Node.js 26 package family,
# including its Fedora-packaged npm 11.x. All other RPMs stay on stable repos;
# this does not persistently enable updates-testing for later DNF commands.
dnf -y --refresh --enable-repo=updates-testing \
  --setopt='updates-testing.includepkgs=nodejs26*' \
  upgrade 'nodejs26*'

# Fish from the shells:fish OBS repository for Fedora 44. The Fedora 44
# build is intentionally used on Fedora 45, for both supported architectures.
# Pin the OBS signing key so a changed key cannot silently be trusted.
fish_version='4.9.3'
fish_release='8.2'
fish_arch=$(rpm --eval '%{_arch}')
case "$fish_arch" in
  x86_64|aarch64) ;;
  *) echo "Unsupported architecture for fish RPM: $fish_arch" >&2; exit 1 ;;
esac
fish_repo='https://download.opensuse.org/repositories/shells:/fish/Fedora_44'
fish_key=$(mktemp)
fish_rpm=$(mktemp --suffix=.rpm)
trap 'rm -f "$fish_key" "$fish_rpm"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  --proto '=https' --proto-redir '=https' \
  --output "$fish_key" "$fish_repo/repodata/repomd.xml.key"
if ! printf '%s  %s\n' \
  'b69c208011dc5923edac16347df77d04d0f0f280c491b6de82d3a72289d45a18' "$fish_key" \
  | sha256sum --check --status; then
  echo 'ERROR: OBS fish signing key differs from the pinned key.' >&2
  exit 1
fi
rpm --import "$fish_key"
curl --fail --silent --show-error --location --retry 3 \
  --proto '=https' --proto-redir '=https' \
  --output "$fish_rpm" "$fish_repo/$fish_arch/fish-${fish_version}-${fish_release}.$fish_arch.rpm"
if ! rpmkeys --checksig "$fish_rpm"; then
  echo 'ERROR: OBS fish RPM signature verification failed.' >&2
  exit 1
fi
dnf -y --setopt=install_weak_deps=False --setopt=localpkg_gpgcheck=True install "$fish_rpm"

# Fedora RPM CVEs are not covered by Trivy's supported distro advisory feeds.
# Check Fedora's own updateinfo after installing every RPM, while DNF's
# refreshed repository metadata is still available. An empty JSON array means
# there are no newer packages associated with published security advisories.
echo 'Checking Fedora security advisories for pending RPM updates...'
if ! advisory_json=$(dnf -q advisory list --security --available --json); then
  echo 'ERROR: Fedora security advisory query failed.' >&2
  exit 1
fi
if ! jq -e 'type == "array"' <<< "$advisory_json" >/dev/null; then
  echo 'ERROR: Fedora advisory query did not return a JSON array.' >&2
  exit 1
fi
advisory_count=$(jq 'length' <<< "$advisory_json")
if (( advisory_count > 0 )); then
  echo "ERROR: ${advisory_count} Fedora security advisory entries have available RPM updates:" >&2
  jq -r '.[] | "  \(.name) [\(.severity)] \(.nevra)"' <<< "$advisory_json" >&2
  exit 1
fi
echo 'Fedora security advisory check passed (no pending published security updates).'

dnf clean all
rm -rf /var/cache/dnf

# Fail image builds if an RPM stops exposing a required CLI.
for binary in fish nano node npm npx corepack python python3 pip3 virtualenv pipx uv rustc cargo go; do
  command -v "$binary" >/dev/null || {
    echo "Missing expected executable after RPM installation: $binary" >&2
    exit 1
  }
done

[[ $(readlink -f "$(command -v python)") == "$(readlink -f "$(command -v python3)")" ]] || {
  echo 'Expected python to resolve to the same Python 3 interpreter as python3.' >&2
  exit 1
}

[[ $(node --version) == v26.* ]] || { echo 'Expected Node.js 26.' >&2; exit 1; }
[[ $(npm --version) == 11.* ]] || { echo 'Expected Fedora npm 11.' >&2; exit 1; }
[[ $(fish --version) == "fish, version $fish_version" ]] || {
  echo "Expected fish $fish_version from OBS." >&2
  exit 1
}
