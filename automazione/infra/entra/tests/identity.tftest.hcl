mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      client_id = "11111111-1111-1111-1111-111111111111"
      object_id = "22222222-2222-2222-2222-222222222222"
      tenant_id = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "azuread_application" {
    defaults = {
      client_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      id        = "/applications/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
      object_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }
  }

  mock_resource "azuread_service_principal" {
    defaults = {
      object_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    }
  }
}

run "primary_oidc_contract" {
  command = plan

  variables {
    tenant_id       = "00000000-0000-0000-0000-000000000001"
    bff_redirect_uri = "https://helpdesk.example.com/api/v1/auth/callback"
    bff_logout_uri   = "https://helpdesk.example.com/"
  }

  assert {
    condition     = azuread_application.api.api[0].requested_access_token_version == 2
    error_message = "The API must explicitly issue v2 access tokens."
  }

  assert {
    condition = toset([
      for role in azuread_application.api.app_role : role.value
    ]) == toset(["tickets.read", "tickets.write", "automation.execute"])
    error_message = "The API must expose exactly the three Helios Desk app roles."
  }

  assert {
    condition = (
      azuread_application.bff.fallback_public_client_enabled == false &&
      azuread_application.bff.web[0].implicit_grant[0].access_token_issuance_enabled == false &&
      azuread_application.bff.web[0].implicit_grant[0].id_token_issuance_enabled == false
    )
    error_message = "The BFF must remain a confidential web client with implicit flow disabled."
  }

  assert {
    condition     = azuread_application.bff.web[0].redirect_uris == toset([var.bff_redirect_uri])
    error_message = "The configured HTTPS callback must be the only BFF redirect URI."
  }

  assert {
    condition     = output.api_audience == azuread_application.api.client_id
    error_message = "The operational v2 audience must be the API client ID GUID."
  }

  assert {
    condition     = output.roles_claim == "roles"
    error_message = "The API authorization contract must use the roles claim."
  }

  assert {
    condition     = output.oidc_runtime_config.audience == output.api_audience
    error_message = "Runtime OIDC output must expose the same API GUID audience."
  }

  assert {
    condition     = length(azuread_app_role_assignment.user_role) == 0
    error_message = "No principal receives a role unless explicitly configured."
  }
}

run "rejects_non_https_callback" {
  command = plan

  variables {
    tenant_id        = "00000000-0000-0000-0000-000000000001"
    bff_redirect_uri = "http://helpdesk.example.com/api/v1/auth/callback"
    bff_logout_uri   = "https://helpdesk.example.com/"
  }

  expect_failures = [var.bff_redirect_uri]
}

run "creates_only_explicit_role_assignments" {
  command = plan

  variables {
    tenant_id        = "00000000-0000-0000-0000-000000000001"
    bff_redirect_uri = "https://helpdesk.example.com/api/v1/auth/callback"
    bff_logout_uri   = "https://helpdesk.example.com/"
    role_assignments = {
      "tickets.read" = ["dddddddd-dddd-4ddd-8ddd-dddddddddddd"]
    }
  }

  assert {
    condition     = length(azuread_app_role_assignment.user_role) == 1
    error_message = "Exactly one configured principal-to-role assignment must be planned."
  }
}
