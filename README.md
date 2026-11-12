# safecli

Run unfamiliar CLI tools in **rootless Podman** with three isolation profiles. All images use the [Fedora Docker Official Image](https://hub.docker.com/_/fedora) (`docker.io/library/fedora:latest`) and enable container networking by default.

| Profile | Isolation and tools | Memory | PIDs |
| --- | --- | ---: | ---: |
| `strict` | Read-only root filesystem, minimal tools, no host-directory mounts | 1.5 GiB | 192 |
| `usb` | As above, plus one explicitly allowed USB/serial device | 1.5 GiB | 192 |
| `nested` | Bubblewrap support; seccomp unconfined **only** for this profile | 3 GiB | 384 |

All profiles use `pasta` networking, `--cap-drop=ALL`, `no-new-privileges`, private namespaces, a 2-CPU limit and a persistent named `/work` volume. No host home directory, SSH agent, display or Podman socket is shared. Use `NETWORK=none` to disable networking when creating a container. Networking permits outbound traffic (including reachable LAN hosts): this is **not** a guarantee that untrusted programs are safe. USB access and the relaxed nested profile increase risk.

## Requirements and usage

Linux, rootless Podman, working cgroup v2/user namespaces and `pasta` (typically the `passt` package) are required. Run as a regular user, **not `sudo`**. USB mode also needs `crun` and host device permissions.

Build locally (fresh Fedora and RPM updates):

```sh
podman build --pull=always --no-cache -f Containerfile.strict -t localhost/safecli-strict:latest .
podman build --pull=always --no-cache -f Containerfile.usb -t localhost/safecli-usb:latest .
podman build --pull=always --no-cache -f Containerfile.nested -t localhost/safecli-nested:latest .
chmod +x safecli.sh
./safecli.sh strict trial /bin/sh
podman cp ./unknown-cli safecli-strict-trial:/work/unknown-cli
./safecli.sh strict trial /work/unknown-cli --help
```

For prebuilt GHCR images, replace `owner/repo` with the lowercase GitHub repository path:

```sh
podman pull ghcr.io/owner/repo-strict:latest
podman pull ghcr.io/owner/repo-usb:latest
podman pull ghcr.io/owner/repo-nested:latest
export IMAGE_PREFIX=ghcr.io/owner/repo
./safecli.sh strict trial
```

Other profile examples:

```sh
USB_DEVICE=/dev/bus/usb/001/005 ./safecli.sh usb device-test
./safecli.sh nested nested-test bwrap --help
NETWORK=none ./safecli.sh strict offline-test
```

`usb` allows only specified USB/serial/hidraw character devices; SELinux may still restrict device access. Nested user namespaces depend on host kernel/LSM settings and may not work on every host. For exact image selection, use `IMAGE='ghcr.io/owner/repo-strict@sha256:REPLACE_WITH_64_HEX_DIGEST'`; `IMAGE_TAG` and `IMAGE_PREFIX` are alternatives. The launcher uses `--pull=never`: pull the image explicitly before creating a sandbox.

Containers and their `/work` volumes persist. To apply a new image, **recreate the container**; restarting it is not enough. Do not delete the named volume unless you want to delete its data:

```sh
podman stop safecli-strict-trial
podman rm safecli-strict-trial
podman pull ghcr.io/owner/repo-strict:latest
IMAGE_PREFIX=ghcr.io/owner/repo ./safecli.sh strict trial
# optional cleanup of data, irreversible: podman volume rm safecli-vol-strict-trial
```

Creation-time settings, including networking and USB device selection, cannot be changed by simply rerunning the launcher against an existing container.

## GHCR publishing and supply-chain security

Commit this project (including `.github/`) to a GitHub repository with default branch `main`. The [workflow](.github/workflows/publish-ghcr.yml) publishes three separate multi-platform images (`linux/amd64`, `linux/arm64`) on pushes to `main`, `v*` tags, manual runs, and **approximately every three days** (04:23 UTC on days 1, 4, 7, ...; not exactly every 72 hours). Pull requests only run validation. Set the GHCR package visibility to **Public** if anonymous pulls are desired; existing packages may need Actions write permission. Publishing uses `GITHUB_TOKEN`, with no PAT or long-lived signing key.

Each publication follows this sequence:

1. Fetch `fedora:latest`, run `dnf upgrade --refresh`, and build both architectures **without layer cache**. Buildx attaches architecture-aware OCI SBOM metadata.
2. Push a **uniquely named candidate** image; Trivy scans **both** architectures, and blocks normal tag promotion for **fixable HIGH or CRITICAL** vulnerabilities or scan errors. Scan JSON reports are saved as Actions artifacts. Candidates may remain in GHCR even if rejected; they are **not** release-approved.
3. Generate downloadable SPDX JSON SBOMs for amd64 and arm64; publish GitHub **provenance and SBOM attestations**, bound to the full image digest and also pushed to GHCR.
4. **Cosign keyless-sign** the digest using GitHub OIDC and verify the expected workflow identity. Only after all checks pass, advance `:latest` (on `main`), a unique `:build-<run_id>-<attempt>` tag, or `:vX.Y.Z` (on a release-tag run). The Actions summary records each digest.

`latest` and version tags are **not immutable** in GHCR. For repeatable use, pin `@sha256:<digest>` and verify the signed identity and provenance. A candidate tag is publicly pullable if the package is public, but never selected by `latest` if checks fail. Existing containers do **not** update on a registry push.

Verify a released image (adjust repository and digest; use the tag reference in `cosign verify` only if it resolves to the expected digest):

```sh
IMAGE='ghcr.io/owner/repo-strict@sha256:REPLACE_WITH_64_HEX_DIGEST'
cosign verify "$IMAGE" \
  --certificate-identity 'https://github.com/owner/repo/.github/workflows/publish-ghcr.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
gh attestation verify "oci://$IMAGE" -R owner/repo
```

For an image published from a `v*` tag, replace `@refs/heads/main` in the Cosign certificate identity with `@refs/tags/vX.Y.Z`. The SBOM and Trivy reports are available in the workflow run's artifacts (30-day retention); Buildx SBOM metadata and signed attestations are attached to the image digest. GitHub Artifact Attestations require a public repository on most non-Enterprise plans; for eligible private repositories, the plan must support private attestations.

**Security-update caveats:** `fedora:latest` follows the latest *stable* Fedora release, not Rawhide, but a major-version change can break builds. GitHub schedules can be delayed or disabled after prolonged inactivity. A failed build or scan leaves the previous `latest` image intact, **which may still have vulnerabilities**. Monitor Actions failures and security advisories, and roll forward image digests on each Podman host. See [SECURITY.md](SECURITY.md).

## License

The project's original scripts, Containerfiles, CI, tests and documentation use the **MIT License** ([LICENSE](LICENSE)). Fedora and all bundled RPM packages retain their **own upstream licenses**; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The project MIT license does not relicense any upstream software.
