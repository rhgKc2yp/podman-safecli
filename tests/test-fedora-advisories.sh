#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify Fedora advisory checks fail closed without needing DNF or network.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
installer="$PWD/scripts/install-cli-toolchain.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"

cat > "$test_dir/bin/dnf" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DNF_CALLS"
case "$*" in
  *'advisory list --security --available --json'*)
    printf '%s\n' "${MOCK_ADVISORY_JSON:-[]}"
    exit "${MOCK_ADVISORY_STATUS:-0}"
    ;;
esac
MOCK
chmod +x "$test_dir/bin/dnf"

# Keep OBS downloads and RPM signature verification offline.
cat > "$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOWNLOADS"
while (($#)); do
  if [[ $1 == --output ]]; then
    printf 'mock download\n' > "$2"
    exit 0
  fi
  shift
done
exit 1
MOCK
cat > "$test_dir/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
[[ ${MOCK_BAD_KEY:-0} == 0 ]]
MOCK
cat > "$test_dir/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --eval) printf '%s\n' "${MOCK_RPM_ARCH:-x86_64}" ;;
  --import) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
cat > "$test_dir/bin/rpmkeys" <<'MOCK'
#!/usr/bin/env bash
[[ ${MOCK_BAD_SIGNATURE:-0} == 0 ]]
MOCK
cat > "$test_dir/bin/npm" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --version ]]; then
  printf '%s\n' "${MOCK_NPM_VERSION:-11.20.0}"
fi
MOCK
cat > "$test_dir/bin/node" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_NODE_VERSION:-v26.13.0}"
MOCK
cat > "$test_dir/bin/fish" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_FISH_VERSION:-fish, version 4.9.3}"
MOCK
chmod +x "$test_dir/bin/"{curl,sha256sum,rpm,rpmkeys,npm,node,fish}

# Mock installed commands so a successful run reaches the final CLI check.
for binary in nano npx corepack python3 pip3 virtualenv pipx uv rustc cargo go; do
  ln -s /usr/bin/true "$test_dir/bin/$binary"
done

export PATH="$test_dir/bin:$PATH"
export MOCK_DNF_CALLS="$test_dir/dnf.calls"
export MOCK_DOWNLOADS="$test_dir/downloads.calls"

MOCK_ADVISORY_JSON='[]' bash "$installer" > "$test_dir/clean.log"
grep -Fq 'Fedora security advisory check passed' "$test_dir/clean.log"
grep -Fq 'clean all' "$MOCK_DNF_CALLS"
grep -Fq 'fish-4.9.3-8.2.x86_64.rpm' "$MOCK_DOWNLOADS"

MOCK_RPM_ARCH=aarch64 bash "$installer" > "$test_dir/arm64.log"
grep -Fq 'fish-4.9.3-8.2.aarch64.rpm' "$MOCK_DOWNLOADS"

for failure_case in bad_key bad_signature wrong_node wrong_npm wrong_fish; do
  case "$failure_case" in
    bad_key) failure_env=(MOCK_BAD_KEY=1) ;;
    bad_signature) failure_env=(MOCK_BAD_SIGNATURE=1) ;;
    wrong_node) failure_env=(MOCK_NODE_VERSION=v22.0.0) ;;
    wrong_npm) failure_env=(MOCK_NPM_VERSION=12.0.0) ;;
    wrong_fish) failure_env=(MOCK_FISH_VERSION='fish, version 4.8.0') ;;
  esac
  if env "${failure_env[@]}" bash "$installer" > "$test_dir/$failure_case.log" 2>&1; then
    echo "ERROR: $failure_case unexpectedly succeeded." >&2
    exit 1
  fi
done

MOCK_ADVISORY_JSON='[{"name":"FEDORA-TEST","severity":"Important","nevra":"openssl-1.0-test.x86_64"}]' \
  bash "$installer" > "$test_dir/pending.log" 2>&1 && {
    echo 'ERROR: Pending Fedora security update did not fail the build.' >&2
    exit 1
  }
grep -Fq 'FEDORA-TEST [Important] openssl-1.0-test.x86_64' "$test_dir/pending.log"

MOCK_ADVISORY_JSON='{"unexpected":"object"}' bash "$installer" > "$test_dir/bad-json.log" 2>&1 && {
  echo 'ERROR: Invalid Fedora advisory result was accepted.' >&2
  exit 1
}
grep -Fq 'did not return a JSON array' "$test_dir/bad-json.log"

MOCK_ADVISORY_STATUS=42 bash "$installer" > "$test_dir/query-fail.log" 2>&1 && {
  echo 'ERROR: Failed Fedora advisory query was accepted.' >&2
  exit 1
}
grep -Fq 'Fedora security advisory query failed' "$test_dir/query-fail.log"

echo 'Fedora advisory success, pending-update, invalid-data and query-error tests passed.'
