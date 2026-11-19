#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Generate complete downloadable SBOMs and size-bounded SBOM attestations.
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${DIGEST:?DIGEST is required}"
: "${SYFT_BIN:?SYFT_BIN is required}"

# actions/attest rejects sbom-path inputs larger than 16 MiB. The override is
# intended for lightweight regression tests; GitHub's real limit is fixed.
max_bytes=${SBOM_ATTEST_MAX_BYTES:-16777216}
[[ "$max_bytes" =~ ^[0-9]+$ ]] && (( max_bytes > 0 )) || {
  echo 'SBOM_ATTEST_MAX_BYTES must be a positive integer.' >&2
  exit 2
}

mkdir -p sboms
for arch in amd64 arm64; do
  source="registry:${IMAGE}@${DIGEST}"
  full="sboms/${arch}.spdx.json"
  attest="sboms/${arch}.attest.spdx.json"

  # Retain Syft's full package and file inventory as a downloadable artifact.
  "$SYFT_BIN" "$source" --platform "linux/$arch" \
    -o "spdx-json=$full"
  test -s "$full"

  # Syft's file cataloger can massively inflate an attested SBOM. Catalog all
  # installed packages but omit file-only cataloging for the signed predicate.
  "$SYFT_BIN" "$source" --platform "linux/$arch" \
    --select-catalogers=-file \
    -o "spdx-json=$attest"
  jq -c . "$attest" > "${attest}.compact"
  mv "${attest}.compact" "$attest"

  coverage='package catalogers (excluding file-only entries)'
  size=$(wc -c < "$attest")
  if (( size > max_bytes )); then
    # Last-resort, explicitly labeled fallback: sign only installed RPMs.
    # The full multi-ecosystem SBOM remains in the workflow artifact and the
    # Buildx SBOM remains attached to the image digest in GHCR.
    echo "::warning::linux/$arch package SBOM is ${size} bytes; signing an RPM-only SBOM instead."
    "$SYFT_BIN" "$source" --platform "linux/$arch" \
      --select-catalogers=rpm \
      -o "spdx-json=$attest"
    jq -c . "$attest" > "${attest}.compact"
    mv "${attest}.compact" "$attest"
    coverage='RPM packages only (fallback)'
    size=$(wc -c < "$attest")
  fi

  if (( size > max_bytes )); then
    echo "ERROR: linux/$arch attestation SBOM is ${size} bytes (limit ${max_bytes})." >&2
    exit 1
  fi
  test -s "$attest"
  jq -e '.packages | type == "array" and length > 0' "$attest" >/dev/null || {
    echo "ERROR: linux/$arch attestation SBOM contains no packages." >&2
    exit 1
  }
  echo "linux/$arch full SBOM: $(wc -c < "$full") bytes; attested $coverage: $size bytes"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf -- '- linux/%s: full SPDX SBOM generated; signed SPDX SBOM covers %s (%s bytes).\n' \
      "$arch" "$coverage" "$size" >> "$GITHUB_STEP_SUMMARY"
  fi
done
