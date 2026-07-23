locals {
  api_display_name = "${var.display_name_prefix} API"
  bff_display_name = "${var.display_name_prefix} BFF"

  owner_object_ids = setunion(
    var.additional_owner_object_ids,
    toset([data.azuread_client_config.current.object_id]),
  )

  app_roles = {
    "tickets.read" = {
      id           = "1c75f553-b165-4f21-8d6f-a42442348c66"
      display_name = "Tickets: read"
      description  = "Read Helios Desk tickets."
    }
    "tickets.write" = {
      id           = "7d7d8bd0-37c4-4f74-b35c-c127df2b371a"
      display_name = "Tickets: write"
      description  = "Create and update Helios Desk tickets."
    }
    "automation.execute" = {
      id           = "faa8b2d1-9fbb-47cf-984a-6017579170f1"
      display_name = "Automation: execute"
      description  = "Execute approved Helios Desk ticket automations."
    }
  }

  delegated_scope = {
    id           = "73f8d732-6bf5-4958-b7ee-79e77646698d"
    value        = "access_as_user"
    display_name = "Access Helios Desk as the signed-in user"
    description  = "Allow the BFF to access Helios Desk on behalf of the signed-in user."
  }

  role_assignment_pairs = {
    for assignment in flatten([
      for role_value, principal_object_ids in var.role_assignments : [
        for principal_object_id in principal_object_ids : {
          key                 = "${role_value}:${principal_object_id}"
          role_value          = role_value
          principal_object_id = principal_object_id
        }
      ]
    ]) : assignment.key => assignment
  }

  api_identifier_uri = "api://${azuread_application.api.client_id}"
  delegated_scope_uri = format(
    "%s/%s",
    local.api_identifier_uri,
    local.delegated_scope.value,
  )

  issuer_url        = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
  authorization_url = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/authorize"
  token_url         = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/token"
  end_session_url   = "https://login.microsoftonline.com/${var.tenant_id}/oauth2/v2.0/logout"
  jwks_url          = "https://login.microsoftonline.com/${var.tenant_id}/discovery/v2.0/keys"
}
