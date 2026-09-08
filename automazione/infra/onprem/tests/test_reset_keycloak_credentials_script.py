#!/usr/bin/env python3
"""Static safety contract for the Keycloak credential-recovery runbook."""

from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reset-keycloak-credentials.sh"


class ResetKeycloakCredentialsScriptTest(unittest.TestCase):
    def test_script_is_valid_bash(self) -> None:
        if os.name == "nt":
            self.skipTest("the recovery script is executed on the Linux control node")
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not available on this host")
        completed = subprocess.run(
            [bash, "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_recovery_is_non_destructive_and_keeps_passwords_out_of_argv(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn("bootstrap-admin", source)
        self.assertIn("- user", source)
        self.assertIn("--password:env", source)
        self.assertIn("RECOVERY_PASSWORD", source)
        self.assertIn("read -r -s", source)
        self.assertIn("--from-file=username=", source)
        self.assertIn("--from-file=password=", source)
        self.assertIn("for external_secret in keycloak-bootstrap-admin helios-dr-operator", source)
        self.assertIn("ExternalSecret/${external_secret}", source)
        self.assertIn("resourceVersion", source)
        self.assertIn('apply -f "${ONPREM_DIR}/identity/network-policies.yaml"', source)
        self.assertIn("bootstrap-admin requires a writable Keycloak image", source)
        self.assertIn("provision-dr-operator.sh", source)

        self.assertNotIn("delete namespace", source)
        self.assertNotIn("delete pvc", source)
        self.assertNotIn("drop database", source)
        self.assertNotIn("--password \"${", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
