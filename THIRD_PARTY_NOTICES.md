# Third-Party Software and License Notices

The `LICENSE` file grants **MIT** permission for the **project-authored scripts, Containerfiles, CI workflows, tests and documentation** only. It does **not** assert copyright ownership over, or relicense, Fedora or third-party software. When distributing the OCI container images, Fedora and each included RPM/dependency continue to be governed by their **own upstream licenses** and applicable attribution, notice, source-availability or redistribution terms.

## Included upstream software

The images are derived from the official Fedora stable container base:

- Fedora Docker Official Image: <https://hub.docker.com/_/fedora>
- Fedora Project: <https://fedoraproject.org/>
- Fedora licensing and policy: <https://docs.fedoraproject.org/en-US/legal/>

Installed third-party RPMs include (dependencies vary by Fedora release and architecture):

- **All profiles:** Fedora base packages plus the shared toolchain from `scripts/install-cli-toolchain.sh` (bash; Node 26/npm 11/Corepack; Python/pip/virtualenv/pipx/uv; Rust/Cargo; Go; native-build prerequisites; essential download, archive and text-processing tools), plus the signed **fish 4.9.3** RPM from the openSUSE Build Service `shells:fish` repository.
- **usb:** shared packages plus `usbutils`, `libusb1`, `libusb1-devel` and dependencies.
- **nested:** shared packages plus `bubblewrap` and dependencies.

The Containerfiles do **not** remove Fedora's installed upstream license files or notices. The OBS fish RPM retains its own upstream license. License details may change as `fedora:latest` advances to newer supported Fedora releases, so a static list of individual package license expressions would become inaccurate.

## Check the actual published image

To list the RPM packages and their *declared license metadata*, for example:

```sh
podman run --rm --entrypoint /bin/sh ghcr.io/owner/repo-strict:latest \
  -c "rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{LICENSE}\n' | sort"
```

Repeat with `repo-usb` and `repo-nested`. The package `License` field is an inventory aid **not a substitute for the complete upstream license text**. Inspect installed `/usr/share/licenses` and `/usr/share/doc` paths (where provided) and the corresponding upstream package sources. When redistributing images, comply with each relevant license's notice, source-offer, and redistribution obligations, rather than assuming the root MIT license applies to all installed software.

This project does not bundle or modify Fedora source code. If you add third-party files later, document their license and preserve any required notices.
