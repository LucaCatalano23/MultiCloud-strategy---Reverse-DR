resource "azuread_application" "api" {
  display_name            = local.api_display_name
  description             = "Helios Desk resource API for the primary Microsoft Entra identity plane."
  owners                  = local.owner_object_ids
  prevent_duplicate_names = true
  sign_in_audience        = "AzureADMyOrg"

  api {
    mapped_claims_enabled           = false
    requested_access_token_version = 2

    oauth2_permission_scope {
      admin_consent_description  = local.delegated_scope.description
      admin_consent_display_name = local.delegated_scope.display_name
      enabled                    = true
      id                         = local.delegated_scope.id
      type                       = "Admin"
      user_consent_description   = local.delegated_scope.description
      user_consent_display_name  = local.delegated_scope.display_name
      value                      = local.delegated_scope.value
    }
  }

  dynamic "app_role" {
    for_each = local.app_roles

    content {
      allowed_member_types = ["User"]
      description          = app_role.value.description
      display_name         = app_role.value.display_name
      enabled              = true
      id                   = app_role.value.id
      value                = app_role.key
    }
  }

  lifecycle {
    # The identifier URI depends on the generated client ID and is managed below.
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "api" {
  application_id = azuread_application.api.id
  identifier_uri = local.api_identifier_uri
}

resource "azuread_service_principal" "api" {
  client_id                    = azuread_application.api.client_id
  description                  = "Enterprise application for Helios Desk API role assignments."
  app_role_assignment_required = true
  owners                       = local.owner_object_ids
}

resource "azuread_application" "bff" {
  display_name                   = local.bff_display_name
  description                    = "Confidential Helios Desk BFF using Authorization Code + PKCE; browser tokens stay server-side."
  fallback_public_client_enabled = false
  owners                         = local.owner_object_ids
  prevent_duplicate_names        = true
  sign_in_audience               = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = local.delegated_scope.id
      type = "Scope"
    }
  }

  web {
    logout_url    = var.bff_logout_uri
    redirect_uris = [var.bff_redirect_uri]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  depends_on = [azuread_service_principal.api]
}

resource "azuread_service_principal" "bff" {
  client_id                    = azuread_application.bff.client_id
  description                  = "Enterprise application for the confidential Helios Desk BFF."
  app_role_assignment_required = false
  owners                       = local.owner_object_ids
}

resource "azuread_app_role_assignment" "user_role" {
  for_each = local.role_assignment_pairs

  app_role_id         = local.app_roles[each.value.role_value].id
  principal_object_id = each.value.principal_object_id
  resource_object_id  = azuread_service_principal.api.object_id
}
