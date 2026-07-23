#!/usr/bin/env python3
"""Static contract tests for the on-prem Kubernetes DR overlay."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
AUTOMAZIONE_ROOT = ROOT.parents[1]
HELPDESK_DR_ROOT = AUTOMAZIONE_ROOT / "helpdesk-dr"
if not HELPDESK_DR_ROOT.is_dir():
    HELPDESK_DR_ROOT = AUTOMAZIONE_ROOT
REALM_TEMPLATE = ROOT / "keycloak" / "realm" / "helios-desk-realm.json"
DEPLOYMENT_CONTRACT = json.loads(
    (AUTOMAZIONE_ROOT / "contracts" / "deployment-contract.json").read_text(
        encoding="utf-8"
    )
)
EXPECTED_APP_DEPLOYMENTS = {
    workload["name"] for workload in DEPLOYMENT_CONTRACT["kubernetes"]["workloads"]
}
EXPECTED_PERMISSIONS = set(DEPLOYMENT_CONTRACT["identity"]["permissions"])


def _render_kustomization() -> str:
    kubectl = os.environ.get("KUBECTL") or shutil.which("kubectl")
    if kubectl is None:
        raise AssertionError("kubectl is required to render the on-prem kustomization")

    completed = subprocess.run(
        [kubectl, "kustomize", str(ROOT)],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise AssertionError(f"kubectl kustomize failed:\n{completed.stderr}")
    return completed.stdout


def _yaml_documents(rendered: str) -> list[str]:
    return [document.strip() for document in rendered.split("\n---\n") if document.strip()]


def _document_value(document: str, key: str) -> str | None:
    prefix = f"{key}:"
    for line in document.splitlines():
        stripped = line.strip()
        if stripped.startswith(prefix):
            return stripped.removeprefix(prefix).strip().strip('"')
    return None


class OnPremManifestContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rendered = _render_kustomization()
        cls.documents = _yaml_documents(cls.rendered)

    def test_expected_workloads_are_declared_with_safe_initial_scaling(self) -> None:
        deployments: dict[str, str] = {}
        for document in self.documents:
            if "kind: Deployment" not in document:
                continue
            name = _document_value(document, "name")
            if name:
                deployments[name] = document

        self.assertTrue(EXPECTED_APP_DEPLOYMENTS.issubset(deployments))
        for name in EXPECTED_APP_DEPLOYMENTS:
            self.assertIn("replicas: 0", deployments[name], name)

        self.assertIn("replicas: 1", deployments["keycloak"])

    def test_no_kubernetes_secret_or_plaintext_credentials_are_rendered(self) -> None:
        self.assertNotIn("kind: Secret", self.rendered)
        forbidden_fragments = (
            "password: admin",
            "password: password",
            "clientSecret:",
            "POSTGRES_PASSWORD: ",
        )
        for fragment in forbidden_fragments:
            self.assertNotIn(fragment, self.rendered)

        self.assertIn("secretKeyRef:", self.rendered)

    def test_identity_and_application_ingress_are_separated(self) -> None:
        self.assertIn("host: auth.azienda.lan", self.rendered)
        self.assertIn("host: helpdesk.azienda.lan", self.rendered)
        self.assertIn("name: helios-bff", self.rendered)
        self.assertIn("name: helios-web", self.rendered)
        self.assertIn("path: /api", self.rendered)
        self.assertIn("path: /", self.rendered)

    def test_bff_uses_keycloak_without_exposing_tokens_to_react(self) -> None:
        self.assertIn("OIDC_ISSUER_URL", self.rendered)
        self.assertIn("https://auth.azienda.lan/realms/helios-desk", self.rendered)
        self.assertIn("OIDC_AUDIENCE", self.rendered)
        self.assertIn("api://reverse-dr-helpdesk", self.rendered)
        self.assertIn("OIDC_ROLES_CLAIM", self.rendered)
        self.assertIn("OIDC_SCOPES", self._deployment_document("helios-bff"))
        self.assertIn("IDENTITY_PROVIDER", self.rendered)
        self.assertIn("IDENTITY_PROVIDER: keycloak", self.rendered)
        self.assertNotIn("OIDC_CLIENT_SECRET", self._deployment_document("helios-web"))

    def test_lambda_dr_configuration_is_scoped_to_automation(self) -> None:
        automation = self._deployment_document("helios-automation-service")
        self.assertIn("AUTOMATION_MODE", automation)
        self.assertIn("LAMBDA_DR_BASE_URL", automation)
        self.assertIn("HELPDESK_LAMBDA_FUNCTION_NAME", automation)
        self.assertNotIn("AUTOMATION_MODE", self._deployment_document("helios-bff"))
        self.assertNotIn(
            "AUTOMATION_MODE", self._deployment_document("helios-ticket-service")
        )

    def test_default_deny_and_explicit_service_flows_are_rendered(self) -> None:
        self.assertGreaterEqual(self.rendered.count("name: default-deny"), 2)
        self.assertIn("name: bff-egress", self.rendered)
        self.assertIn("name: web-egress", self.rendered)
        self.assertIn("name: keycloak-postgres-ingress", self.rendered)
        self.assertIn("kubernetes.io/metadata.name: lambda-dr", self.rendered)

    def test_react_runtime_contract_uses_the_bff_csrf_cookie(self) -> None:
        # runtime-config.json is rendered at container start by
        # apps/frontend/deploy/40-runtime-config.sh from these Dockerfile
        # ENV defaults into a writable emptyDir; no ConfigMap is involved.
        dockerfile = (
            AUTOMAZIONE_ROOT / "apps" / "frontend" / "Dockerfile"
        ).read_text(encoding="utf-8")
        self.assertIn("HELIOS_API_BASE_PATH=/api/v1", dockerfile)
        self.assertIn("HELIOS_DEMO_MODE=false", dockerfile)
        self.assertIn("HELIOS_CSRF_COOKIE_NAME=__Host-helios_csrf", dockerfile)
        self.assertIn("HELIOS_CSRF_HEADER_NAME=X-CSRF-Token", dockerfile)

        template = (
            AUTOMAZIONE_ROOT
            / "apps"
            / "frontend"
            / "deploy"
            / "runtime-config.json.template"
        ).read_text(encoding="utf-8")
        self.assertIn('"appName": "Helios Desk"', template)
        self.assertIn("${HELIOS_API_BASE_PATH}", template)
        self.assertIn("${HELIOS_CSRF_COOKIE_NAME}", template)

        rendered = self.rendered
        self.assertNotIn("helios-web-runtime", rendered)
        web_deployment = self._deployment_document("helios-web")
        self.assertIn("mountPath: /usr/share/nginx/html/config\n", web_deployment)

    def _deployment_document(self, deployment_name: str) -> str:
        for document in self.documents:
            if (
                "kind: Deployment" in document
                and _document_value(document, "name") == deployment_name
            ):
                return document
        self.fail(f"missing Deployment/{deployment_name}")


class RealmContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.realm = json.loads(REALM_TEMPLATE.read_text(encoding="utf-8"))

    def test_bff_client_secret_is_an_environment_placeholder(self) -> None:
        bff = next(client for client in self.realm["clients"] if client["clientId"] == "helios-bff")
        self.assertEqual("${HELIOS_BFF_CLIENT_SECRET}", bff["secret"])
        self.assertFalse(bff["publicClient"])
        self.assertFalse(bff["directAccessGrantsEnabled"])
        self.assertFalse(bff["fullScopeAllowed"])
        self.assertEqual(["S256"], bff["attributes"]["pkce.code.challenge.method"].split())

    def test_roles_claim_and_audience_match_the_entra_contract(self) -> None:
        self.assertEqual(
            EXPECTED_PERMISSIONS,
            {
                role["name"]
                for role in self.realm["roles"]["client"]["helios-api"]
            },
        )

        bff = next(client for client in self.realm["clients"] if client["clientId"] == "helios-bff")
        mappers = {mapper["name"]: mapper for mapper in bff["protocolMappers"]}
        self.assertEqual("roles", mappers["roles"]["config"]["claim.name"])
        self.assertEqual(
            "${HELIOS_API_AUDIENCE}",
            mappers["api-audience"]["config"]["included.custom.audience"],
        )
        bff_scope = self.realm["clientScopeMappings"]["helios-bff"]
        self.assertEqual("helios-api", bff_scope[0]["client"])
        self.assertEqual(EXPECTED_PERMISSIONS, set(bff_scope[0]["roles"]))

    def test_realm_template_does_not_seed_users_or_passwords(self) -> None:
        self.assertNotIn("users", self.realm)
        serialized = json.dumps(self.realm)
        self.assertNotIn('"password"', serialized.lower())


class ExistingDrIntegrationContractTest(unittest.TestCase):
    def test_ansible_remains_the_failover_orchestrator(self) -> None:
        playbook = (
            HELPDESK_DR_ROOT
            / "ansible"
            / "playbooks"
            / "failover.yml"
        ).read_text(encoding="utf-8")
        promote = (
            HELPDESK_DR_ROOT
            / "scripts"
            / "failover"
            / "promote-onprem.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("scripts/failover/promote-onprem.sh", playbook)
        self.assertIn("HELIOS_DR_WORKLOADS", playbook)
        self.assertIn("DR_ACTIVE=true", promote)
        self.assertIn("OIDC_ISSUER_URL", promote)
        self.assertIn("kubectl", promote)
        self.assertIn("scale", promote)

    def test_operator_provisioning_is_external_to_the_realm_and_assigns_roles(self) -> None:
        provisioner = (
            ROOT / "keycloak" / "provision" / "provision-dr-operator.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("set-password", provisioner)
        self.assertIn("--temporary", provisioner)
        for permission in EXPECTED_PERMISSIONS:
            self.assertIn(f"--rolename {permission}", provisioner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
