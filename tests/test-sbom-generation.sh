#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Verify the size-bounded SBOM path preserves a full downloadable SBOM.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
script="$PWD/scripts/generate-sboms.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Mock Syft's output without fetching images or needing registry credentials.
cat > "$test_dir/syft" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target=''
catalogers='all'
for arg in "$@"; do
  case "$arg" in
    spdx-json=*) target=${arg#spdx-json=} ;;
    --select-catalogers=*) catalogers=${arg#--select-catalogers=} ;;
  esac
done
[[ -n "$target" ]]
case "$catalogers" in
  all)
    [[ "${SYFT_FILE_METADATA_SELECTION:-}" != none ]] || exit 1
    printf '{"packages":[{"name":"full"}],"files":[{"name":"file"}]}\n' > "$target"
    ;;
  -file)
    [[ "${SYFT_FILE_METADATA_SELECTION:-}" == none ]] || exit 1
    printf '{"packages":[{"name":"normal","padding":"0123456789012345678901234567890123456789"}]}\n' > "$target"
    ;;
  rpm)
    [[ "${SYFT_FILE_METADATA_SELECTION:-}" == none ]] || exit 1
    printf '{"packages":[{"name":"rpm"}]}\n' > "$target"
    ;;
  *) echo "Unexpected catalogers: $catalogers" >&2; exit 1 ;;
esac
MOCK
chmod +x "$test_dir/syft"

mkdir -p "$test_dir/normal" "$test_dir/fallback" "$test_dir/fail"
(
  cd "$test_dir/normal"
  IMAGE=ghcr.io/example/test DIGEST=sha256:abc SYFT_BIN="$test_dir/syft" \
    SBOM_ATTEST_MAX_BYTES=150 bash "$script"
  for arch in amd64 arm64; do
    jq -e '.files[0].name == "file"' "sboms/$arch.spdx.json" >/dev/null
    jq -e '.packages[0].name == "normal"' "sboms/$arch.attest.spdx.json" >/dev/null
  done
)
(
  cd "$test_dir/fallback"
  IMAGE=ghcr.io/example/test DIGEST=sha256:abc SYFT_BIN="$test_dir/syft" \
    GITHUB_STEP_SUMMARY="$test_dir/summary" SBOM_ATTEST_MAX_BYTES=50 bash "$script"
  for arch in amd64 arm64; do
    jq -e '.files[0].name == "file"' "sboms/$arch.spdx.json" >/dev/null
    jq -e '.packages[0].name == "rpm"' "sboms/$arch.attest.spdx.json" >/dev/null
  done
  grep -Fq 'RPM packages only (fallback)' "$test_dir/summary"
)
(
  cd "$test_dir/fail"
  if IMAGE=ghcr.io/example/test DIGEST=sha256:abc SYFT_BIN="$test_dir/syft" \
    SBOM_ATTEST_MAX_BYTES=10 bash "$script" > /dev/null 2>&1; then
    echo 'Oversized fallback SBOM unexpectedly passed.' >&2
    exit 1
  fi
)

echo 'Size-bounded SBOM generation and fallback checks passed.'
