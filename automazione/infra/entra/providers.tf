provider "azuread" {
  tenant_id = var.tenant_id
}

data "azuread_client_config" "current" {}
