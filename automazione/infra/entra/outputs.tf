output "tenant_id" {
  description = "Microsoft Entra tenant GUID used by the primary OIDC configuration."
  value       = var.tenant_id
}

output "api_client_id" {
  description = "Client ID GUID of the Helios Desk API app registration."
  value       = azuread_application.api.client_id
}

output "api_application_object_id" {
  description = "Tenant-local object ID of the Helios Desk API app registration."
  value       = azuread_application.api.object_id
}

output "api_service_principal_object_id" {
  description = "Tenant-local object ID of the Helios Desk API enterprise application."
  value       = azuread_service_principal.api.object_id
}

output "api_identifier_uri" {
  description = "Identifier URI used when requesting the delegated API scope. This is not the v2 token audience."
  value       = local.api_identifier_uri
}

output "api_audience" {
  description = "Operational aud value for Entra v2 access-token validation: the API client ID GUID. Configure Keycloak DR with this exact value."
  value       = azuread_application.api.client_id
}

output "api_delegated_scope" {
  description = "Fully qualified delegated scope requested by the BFF."
  value       = local.delegated_scope_uri
}

output "api_app_role_ids" {
  description = "Stable app-role IDs keyed by the values emitted in the roles claim."
  value = {
    for role_value, role in local.app_roles : role_value => role.id
  }
}

output "bff_client_id" {
  description = "Client ID GUID of the confidential Helios Desk BFF app registration."
  value       = azuread_application.bff.client_id
}

output "bff_application_object_id" {
  description = "Tenant-local object ID of the Helios Desk BFF app registration."
  value       = azuread_application.bff.object_id
}

output "bff_service_principal_object_id" {
  description = "Tenant-local object ID of the Helios Desk BFF enterprise application."
  value       = azuread_service_principal.bff.object_id
}

output "roles_claim" {
  description = "JWT claim containing assigned Helios Desk API app-role values."
  value       = "roles"
}

output "oidc_runtime_config" {
  description = "Non-secret BFF and resource-server configuration for the Entra primary identity plane."
  value = {
    tenant_id                 = var.tenant_id
    issuer                    = local.issuer_url
    jwks_url                  = local.jwks_url
    authorization_endpoint    = local.authorization_url
    token_endpoint            = local.token_url
    end_session_endpoint      = local.end_session_url
    client_id                 = azuread_application.bff.client_id
    audience                  = azuread_application.api.client_id
    redirect_uri              = var.bff_redirect_uri
    post_logout_redirect_uri  = var.bff_logout_uri
    roles_claim               = "roles"
    required_algorithms       = ["RS256"]
    authorization_code_scopes = [
      "openid",
      "profile",
      "email",
      local.delegated_scope_uri,
    ]
  }
}
