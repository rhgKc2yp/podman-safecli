#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fast argument-assembly tests; no Podman daemon or privileged features needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export MOCK_PODMAN_CREATE="$tmp/create.args"

cat > "$tmp/bin/podman" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  container) [[ "${2:-}" == exists ]] && exit 1 ;;
  image) [[ "${2:-}" == exists ]] && exit 0 ;;
  create) printf '%s\n' "$@" > "$MOCK_PODMAN_CREATE" ;;
  inspect)
    case "${3:-}" in
      *State.Running*) echo true ;;
      *) echo missing ;;
    esac
    ;;
  start|exec) exit 0 ;;
  *) echo "Unexpected mocked Podman call: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in -u|-g) echo 1000 ;; *) /usr/bin/id "$@" ;; esac
MOCK
chmod +x "$tmp/bin/podman" "$tmp/bin/id"
export PATH="$tmp/bin:$PATH"
unset NETWORK IMAGE IMAGE_PREFIX IMAGE_TAG USB_DEVICE

has_arg() { grep -Fqx -- "$1" "$MOCK_PODMAN_CREATE"; }
not_arg() { ! has_arg "$1"; }

./safecli.sh strict mock-strict true
has_arg '--network=pasta'
has_arg '--pids-limit=192'
has_arg '--memory=1536m'
has_arg '--memory-swap=1536m'
has_arg '--read-only'
not_arg '--security-opt=seccomp=unconfined'

./safecli.sh nested mock-nested true
has_arg '--network=pasta'
has_arg '--pids-limit=384'
has_arg '--memory=3g'
has_arg '--security-opt=seccomp=unconfined'
not_arg '--read-only'

NETWORK=none ./safecli.sh strict mock-offline true
has_arg '--network=none'

if NETWORK=invalid ./safecli.sh strict invalid true 2>/dev/null; then
  echo 'ERROR: invalid NETWORK was accepted' >&2
  exit 1
fi
if ./safecli.sh usb missing-device true 2>/dev/null; then
  echo 'ERROR: usb mode without USB_DEVICE was accepted' >&2
  exit 1
fi

echo 'All safecli launcher tests passed.'
