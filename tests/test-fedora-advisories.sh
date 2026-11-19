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

# Mock installed commands so a successful run reaches the final CLI check.
for binary in fish nano node npm npx corepack python3 pip3 virtualenv pipx uv rustc cargo go; do
  ln -s /usr/bin/true "$test_dir/bin/$binary"
done

export PATH="$test_dir/bin:$PATH"
export MOCK_DNF_CALLS="$test_dir/dnf.calls"

MOCK_ADVISORY_JSON='[]' bash "$installer" > "$test_dir/clean.log"
grep -Fq 'Fedora security advisory check passed' "$test_dir/clean.log"
grep -Fq 'clean all' "$MOCK_DNF_CALLS"

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
