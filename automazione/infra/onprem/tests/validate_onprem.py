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
        # Confronto per riga intera e non per sottostringa: da quando i segreti
        # arrivano da OpenBao, l'overlay contiene legittimamente `kind: SecretStore`
        # e `kind: ExternalSecret`, di cui "kind: Secret" e' prefisso. Un
        # assertNotIn su sottostringa fallirebbe su manifest corretti e, cosa
        # peggiore, spingerebbe a rimuovere il controllo invece di precisarlo.
        rendered_kinds = {
            line.strip() for line in self.rendered.splitlines() if line.startswith("kind:")
        }
        self.assertNotIn("kind: Secret", rendered_kinds)
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
        self.assertIn("host: heliospoc.terna.it", self.rendered)
        self.assertIn("name: helios-bff", self.rendered)
        self.assertIn("name: helios-web", self.rendered)
        self.assertIn("path: /api", self.rendered)
        self.assertIn("path: /", self.rendered)

    def test_keycloak_redirects_back_to_the_canonical_application_origin(self) -> None:
        bff = self._deployment_document("helios-bff")
        self.assertIn(
            "OIDC_REDIRECT_URI: https://heliospoc.terna.it/api/v1/auth/callback",
            self.rendered,
        )
        self.assertIn(
            "OIDC_POST_LOGOUT_REDIRECT_URI: https://heliospoc.terna.it/",
            self.rendered,
        )
        self.assertIn(
            "APPLICATION_PUBLIC_ORIGIN: https://heliospoc.terna.it",
            self.rendered,
        )
        self.assertIn("APPLICATION_PUBLIC_ORIGIN", bff)
        self.assertIn("OIDC_CLIENT_AUTH_METHOD: client_secret", self.rendered)
        self.assertIn("name: OIDC_CLIENT_AUTH_METHOD", bff)
        self.assertIn("name: IDENTITY_PROVIDER", bff)

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
        self.assertIn("name: identity-recovery-egress", self.rendered)
        postgres_policy = (ROOT / "identity" / "postgres.yaml").read_text(encoding="utf-8")
        self.assertIn("app.kubernetes.io/component: identity-recovery", postgres_policy)
        self.assertIn("kubernetes.io/metadata.name: lambda-dr", self.rendered)
        # Il Job effimero di migrazione schema (scripts/apply-migrations.sh) deve
        # avere una egress dedicata (DNS + PostgreSQL applicativo) sotto default-deny.
        self.assertIn("name: db-migrate-egress", self.rendered)

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

    def test_bff_client_accepts_only_the_canonical_application_origin(self) -> None:
        bff = next(
            client
            for client in self.realm["clients"]
            if client["clientId"] == "helios-bff"
        )
        self.assertEqual(
            ["https://heliospoc.terna.it/api/v1/auth/callback"],
            bff["redirectUris"],
        )
        self.assertEqual(["https://heliospoc.terna.it"], bff["webOrigins"])
        self.assertEqual(
            "https://heliospoc.terna.it/",
            bff["attributes"]["post.logout.redirect.uris"],
        )

    def test_roles_claim_and_audience_match_the_entra_contract(self) -> None:
        self.assertEqual(
            EXPECTED_PERMISSIONS,
            {
                role["name"]
                for role in self.realm["roles"]["client"]["helios-api"]
            },
        )

        # These mappers live on the "roles" client scope, not as dedicated
        # (client-level) mappers: Keycloak 26.7's generate-example-id-token
        # tool confirmed dedicated mappers are listed as applicable but are
        # silently omitted from issued tokens, while client-scope mappers
        # are applied correctly. helios-bff has "roles" as a default scope,
        # so this still applies to every token it is issued.
        roles_scope = next(s for s in self.realm["clientScopes"] if s["name"] == "roles")
        mappers = {mapper["name"]: mapper for mapper in roles_scope["protocolMappers"]}
        roles_mapper = mappers["roles"]
        self.assertEqual("oidc-usermodel-client-role-mapper", roles_mapper["protocolMapper"])
        self.assertEqual("helios-api", roles_mapper["config"]["usermodel.clientRoleMapping.clientId"])
        self.assertEqual("roles", roles_mapper["config"]["claim.name"])
        self.assertEqual("true", roles_mapper["config"]["multivalued"])
        self.assertEqual("true", roles_mapper["config"]["access.token.claim"])
        self.assertEqual("true", roles_mapper["config"]["id.token.claim"])
        self.assertEqual(
            "${HELIOS_API_AUDIENCE}",
            mappers["api-audience"]["config"]["included.custom.audience"],
        )
        bff = next(client for client in self.realm["clients"] if client["clientId"] == "helios-bff")
        self.assertIn("roles", bff.get("defaultClientScopes", []))
        bff_scope = self.realm["clientScopeMappings"]["helios-bff"]
        self.assertEqual("helios-api", bff_scope[0]["client"])
        self.assertEqual(EXPECTED_PERMISSIONS, set(bff_scope[0]["roles"]))

    def test_realm_template_does_not_seed_users_or_passwords(self) -> None:
        self.assertNotIn("users", self.realm)
        serialized = json.dumps(self.realm)
        self.assertNotIn('"password"', serialized.lower())

    def test_referenced_client_scopes_are_actually_defined(self) -> None:
        # A partial realm import (as opposed to creating a realm through the
        # admin console/API) does not auto-create Keycloak's built-in scopes
        # (profile, email, roles, ...). Referencing them by name without a
        # matching "clientScopes" entry silently drops their protocol
        # mappers from every issued token (roles/employee_id go missing)
        # instead of failing the import outright.
        defined = {scope["name"] for scope in self.realm.get("clientScopes", [])}
        referenced = set(self.realm.get("defaultDefaultClientScopes", [])) | set(
            self.realm.get("defaultOptionalClientScopes", [])
        )
        self.assertTrue(
            referenced.issubset(defined),
            f"referenced but undefined client scopes: {referenced - defined}",
        )
        roles_scope = next(s for s in self.realm["clientScopes"] if s["name"] == "roles")
        self.assertEqual("openid-connect", roles_scope["protocol"])

        # "basic" carries Keycloak's oidc-sub-mapper (the access token's
        # "sub" claim). It is not implied by realm-level defaults on every
        # import path, so helios-bff must list it explicitly, or resource
        # servers reject the access token outright (MissingRequiredClaimError).
        basic_scope = next(s for s in self.realm["clientScopes"] if s["name"] == "basic")
        mapper_types = {m["protocolMapper"] for m in basic_scope["protocolMappers"]}
        self.assertIn("oidc-sub-mapper", mapper_types)
        bff = next(c for c in self.realm["clients"] if c["clientId"] == "helios-bff")
        self.assertIn("basic", bff.get("defaultClientScopes", []))


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

    def test_operator_provisioning_repairs_the_bff_token_contract(self) -> None:
        provisioner = (
            ROOT / "keycloak" / "provision" / "provision-dr-operator.sh"
        ).read_text(encoding="utf-8")
        runner = (ROOT / "scripts" / "provision-dr-operator.sh").read_text(
            encoding="utf-8"
        )

        # Startup realm import is create-only. Provisioning must therefore
        # repair these live-realm relations on every run, before assigning
        # roles to the operator.
        self.assertIn("default-client-scopes", provisioner)
        self.assertIn("protocol-mappers/models", provisioner)
        self.assertIn("scope-mappings/clients", provisioner)
        self.assertIn("evaluate-scopes/scope-mappings", provisioner)
        self.assertIn("generate-example-id-token", provisioner)
        self.assertIn("generate-example-access-token", provisioner)
        self.assertNotIn("awk", provisioner)
        self.assertIn("CURRENT_STEP", provisioner)
        self.assertIn("Provisioning step:", provisioner)
        self.assertIn("Provisioning failed during", provisioner)
        self.assertIn("mapper_update_file", provisioner)
        self.assertIn('"id": "%s"', provisioner)
        self.assertIn("create configmap", runner)
        self.assertIn("helios-identity-provisioner", runner)
        self.assertIn("--from-file", runner)
        self.assertIn("Refreshing provisioner ConfigMap", runner)
        self.assertIn("job-name=${JOB}", runner)
        self.assertIn("--all-containers=true", runner)
        self.assertIn('describe "job/${JOB}"', runner)
        self.assertIn('logs deployment/keycloak', runner)
        self.assertIn('--since=10m', runner)


if __name__ == "__main__":
    unittest.main(verbosity=2)
