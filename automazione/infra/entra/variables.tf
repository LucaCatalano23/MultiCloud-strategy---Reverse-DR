variable "tenant_id" {
  description = "Microsoft Entra tenant GUID that owns both Helios Desk app registrations."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID."
  }
}

variable "display_name_prefix" {
  description = "Human-readable prefix for the API and BFF app registrations."
  type        = string
  default     = "Helios Desk"

  validation {
    condition = (
      length(trimspace(var.display_name_prefix)) >= 3 &&
      length(trimspace(var.display_name_prefix)) <= 80
    )
    error_message = "display_name_prefix must contain between 3 and 80 non-whitespace characters."
  }
}

variable "bff_redirect_uri" {
  description = "Exact HTTPS callback URI used by the BFF Authorization Code + PKCE flow."
  type        = string

  validation {
    condition     = can(regex("^https://[^/\\s#]+(?:/[^\\s#]*)?$", var.bff_redirect_uri))
    error_message = "bff_redirect_uri must be an absolute HTTPS URI without a fragment."
  }
}

variable "bff_logout_uri" {
  description = "Exact HTTPS front-channel logout and post-logout return URI for the BFF."
  type        = string

  validation {
    condition     = can(regex("^https://[^/\\s#]+(?:/[^\\s#]*)?$", var.bff_logout_uri))
    error_message = "bff_logout_uri must be an absolute HTTPS URI without a fragment."
  }
}

variable "additional_owner_object_ids" {
  description = "Additional Entra user or service-principal object IDs that own both applications and service principals. The Terraform caller is always included."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for object_id in var.additional_owner_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", object_id))
    ])
    error_message = "Every additional owner object ID must be a valid GUID."
  }
}

variable "role_assignments" {
  description = "Map of Helios API role value to explicitly authorized user/group/service-principal object IDs. Empty is fail-closed."
  type        = map(set(string))
  default     = {}

  validation {
    condition = alltrue([
      for role_value in keys(var.role_assignments) :
      contains(["tickets.read", "tickets.write", "automation.execute"], role_value)
    ])
    error_message = "role_assignments keys must be tickets.read, tickets.write, or automation.execute."
  }

  validation {
    condition = alltrue([
      for principal_object_ids in values(var.role_assignments) :
      length(principal_object_ids) > 0 && alltrue([
        for object_id in principal_object_ids :
        can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", object_id))
      ])
    ])
    error_message = "Every configured role must contain one or more valid principal object GUIDs."
  }
}
