#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Offline regression tests for the signed OBS fish RPM update detector."""

import gzip
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("update_obs_fish", ROOT / "scripts/update-obs-fish.py")
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


def primary(arches, *, versions=None):
    versions = versions or {}
    packages = []
    for arch in arches:
        ver, rel = versions.get(arch, ("4.10.0", "1.1"))
        packages.append(
            f'<package><name>fish</name><arch>{arch}</arch>'
            f'<version epoch="0" ver="{ver}" rel="{rel}"/>'
            f'<location href="{arch}/fish-{ver}-{rel}.{arch}.rpm"/></package>'
        )
    return (
        '<metadata xmlns="http://linux.duke.edu/metadata/common">'
        + "".join(packages)
        + "</metadata>"
    ).encode()


class FishUpdateTests(unittest.TestCase):
    def test_valid_both_architectures(self):
        self.assertEqual(updater.fish_packages(primary(updater.ARCHES)), ("4.10.0", "1.1"))

    def test_missing_architecture_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "both"):
            updater.fish_packages(primary(["x86_64"]))

    def test_architecture_version_mismatch_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "differ"):
            updater.fish_packages(primary(updater.ARCHES, versions={"aarch64": ("4.9.9", "8.2")}))

    def test_unexpected_architecture_path_fails_closed(self):
        xml = primary(updater.ARCHES).replace(b"aarch64/fish-", b"x86_64/fish-")
        with self.assertRaisesRegex(ValueError, "location"):
            updater.fish_packages(xml)

    def test_numeric_rpm_version_ordering(self):
        self.assertGreater(updater.version_key(("4.10.0", "1.1")),
                           updater.version_key(("4.9.3", "8.2")))
        self.assertGreater(updater.version_key(("4.9.3", "9.1")),
                           updater.version_key(("4.9.3", "8.2")))

    def test_primary_metadata_path_checked(self):
        digest = "a" * 64
        xml = (
            '<repomd xmlns="http://linux.duke.edu/metadata/repo">'
            f'<data type="primary"><checksum type="sha256">{digest}</checksum>'
            f'<location href="repodata/{digest}-primary.xml.gz"/></data></repomd>'
        ).encode()
        self.assertEqual(updater.primary_metadata(xml),
                         (f"repodata/{digest}-primary.xml.gz", digest))
        with self.assertRaisesRegex(ValueError, "path"):
            updater.primary_metadata(xml.replace(b"repodata/", b"../"))

    def test_update_changes_only_pinned_version_and_documentation(self):
        with tempfile.TemporaryDirectory(prefix="safecli-fish-test-") as tmp:
            tmp_path = Path(tmp)
            installer = tmp_path / "installer.sh"
            readme = tmp_path / "README.md"
            notices = tmp_path / "THIRD_PARTY_NOTICES.md"
            installer.write_text(updater.INSTALLER.read_text())
            readme.write_text(updater.README.read_text())
            notices.write_text(updater.NOTICES.read_text())

            with patch.object(updater, "INSTALLER", installer), \
                 patch.object(updater, "README", readme), \
                 patch.object(updater, "NOTICES", notices):
                old = updater.read_version(installer.read_text())
                planned = updater.plan_changes(old, ("999.0.0", "1.1"))
                self.assertEqual(len(planned), 3)
                self.assertIn("fish_version='999.0.0'", planned[installer])
                self.assertIn("fish_release='1.1'", planned[installer])
                self.assertIn("fish **999.0.0**", planned[readme])
                self.assertIn("**fish 999.0.0**", planned[notices])
                self.assertIn(f"fish_version='{old[0]}'", installer.read_text())

    def test_main_proposes_update_from_validated_metadata(self):
        with tempfile.TemporaryDirectory(prefix="safecli-fish-update-") as tmp:
            tmp_path = Path(tmp)
            installer = tmp_path / "installer.sh"
            readme = tmp_path / "README.md"
            notices = tmp_path / "THIRD_PARTY_NOTICES.md"
            installer.write_text(updater.INSTALLER.read_text())
            readme.write_text(updater.README.read_text())
            notices.write_text(updater.NOTICES.read_text())

            fish_xml = gzip.compress(primary(updater.ARCHES))
            checksum = hashlib.sha256(fish_xml).hexdigest()
            primary_path = f"repodata/{checksum}-primary.xml.gz"
            repomd = (
                '<repomd xmlns="http://linux.duke.edu/metadata/repo">'
                f'<data type="primary"><checksum type="sha256">{checksum}</checksum>'
                f'<location href="{primary_path}"/></data></repomd>'
            ).encode()
            fake_key = b"offline test key"
            responses = {
                "repodata/repomd.xml.key": fake_key,
                "repodata/repomd.xml": repomd,
                "repodata/repomd.xml.asc": b"test detached signature",
                primary_path: fish_xml,
            }

            with patch.object(updater, "ROOT", tmp_path), \
                 patch.object(updater, "INSTALLER", installer), \
                 patch.object(updater, "README", readme), \
                 patch.object(updater, "NOTICES", notices), \
                 patch.object(updater, "fetch", side_effect=lambda path, limit: responses[path]), \
                 patch.object(updater, "pinned_key_sha256",
                              return_value=hashlib.sha256(fake_key).hexdigest()), \
                 patch.object(updater, "verify_signed_metadata") as verify:
                updater.main()
                verify.assert_called_once_with(repomd, responses["repodata/repomd.xml.asc"], fake_key)

            self.assertIn("fish_version='4.10.0'", installer.read_text())
            self.assertIn("fish_release='1.1'", installer.read_text())
            self.assertIn("fish **4.10.0**", readme.read_text())


if __name__ == "__main__":
    unittest.main()
