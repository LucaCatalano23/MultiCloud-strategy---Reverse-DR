$ErrorActionPreference = 'Stop'

$terraformRoot = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
  'versions.tf',
  'providers.tf',
  'locals.tf',
  'variables.tf',
  'main.tf',
  'outputs.tf',
  'terraform.tfvars.example',
  'README.md',
  'tests/identity.tftest.hcl'
)

$missingFiles = @(
  foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $terraformRoot $relativePath))) {
      $relativePath
    }
  }
)

if ($missingFiles.Count -gt 0) {
  throw "Missing Entra Terraform contract files: $($missingFiles -join ', ')"
}

$terraformSource = Get-ChildItem -LiteralPath $terraformRoot -Filter '*.tf' -File |
  ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw } |
  Out-String
$readmeSource = Get-Content -LiteralPath (Join-Path $terraformRoot 'README.md') -Raw

$requiredTerraformPatterns = [ordered]@{
  'API application registration'      = 'resource\s+"azuread_application"\s+"api"'
  'BFF application registration'      = 'resource\s+"azuread_application"\s+"bff"'
  'API v2 access tokens'               = 'requested_access_token_version\s*=\s*2'
  'API identifier URI'                 = 'resource\s+"azuread_application_identifier_uri"'
  'Delegated access scope'             = 'value\s*=\s*"access_as_user"'
  'API service principal'              = 'resource\s+"azuread_service_principal"\s+"api"'
  'BFF service principal'              = 'resource\s+"azuread_service_principal"\s+"bff"'
  'Explicit user role assignments'     = 'resource\s+"azuread_app_role_assignment"'
  'Confidential client fallback'       = 'fallback_public_client_enabled\s*=\s*false'
  'No implicit access token flow'      = 'access_token_issuance_enabled\s*=\s*false'
  'No implicit ID token flow'          = 'id_token_issuance_enabled\s*=\s*false'
  'Web redirect URI variable'          = 'redirect_uris\s*=\s*\[var\.bff_redirect_uri\]'
  'Web logout URI variable'            = 'logout_url\s*=\s*var\.bff_logout_uri'
  'BFF delegated API declaration'      = '(?s)required_resource_access\s*\{.*?type\s*=\s*"Scope"'
  'GUID API audience output'            = '(?s)output\s+"api_audience"\s*\{.*?azuread_application\.api\.client_id'
  'Roles claim output'                 = '(?s)output\s+"roles_claim"\s*\{.*?"roles"'
  'HTTPS redirect validation'          = '(?s)variable\s+"bff_redirect_uri"\s*\{.*?https://'
  'HTTPS logout validation'            = '(?s)variable\s+"bff_logout_uri"\s*\{.*?https://'
}

$failedTerraformChecks = @(
  foreach ($entry in $requiredTerraformPatterns.GetEnumerator()) {
    if ($terraformSource -notmatch $entry.Value) {
      $entry.Key
    }
  }
)

foreach ($roleValue in @('tickets.read', 'tickets.write', 'automation.execute')) {
  if ($terraformSource -notmatch "`"$([regex]::Escape($roleValue))`"") {
    $failedTerraformChecks += "App role $roleValue"
  }
}

if ($failedTerraformChecks.Count -gt 0) {
  throw "Entra Terraform static contract checks failed: $($failedTerraformChecks -join ', ')"
}

$forbiddenTerraformPatterns = [ordered]@{
  'Terraform-managed client secret' = 'resource\s+"azuread_application_password"'
  'Inline application password'     = '(?m)^\s*password\s*\{'
  'Hard-coded client secret value'  = '(?im)^\s*(client_secret|secret|password)\s*=\s*"[^"$]+"'
  'Implicit grant enabled'          = '(access_token_issuance_enabled|id_token_issuance_enabled)\s*=\s*true'
  'Non-HTTPS example redirect'      = '(?im)^\s*bff_(redirect|logout)_uri\s*=\s*"http://'
}

$securityFailures = @(
  foreach ($entry in $forbiddenTerraformPatterns.GetEnumerator()) {
    if ($terraformSource -match $entry.Value) {
      $entry.Key
    }
  }
)

if ($securityFailures.Count -gt 0) {
  throw "Entra Terraform security checks failed: $($securityFailures -join ', ')"
}

$requiredDocumentationPatterns = [ordered]@{
  'Authorization Code flow'  = 'Authorization Code'
  'PKCE S256'                = 'PKCE.*S256|S256.*PKCE'
  'v2 GUID audience'         = 'v2.*audience.*GUID|audience.*v2.*GUID'
  'Keycloak DR parity'       = 'Keycloak.*(same|stesso).*GUID|Keycloak.*GUID'
  'Roles claim'              = 'claim\s+`?roles`?|`roles`\s+claim'
  'Out-of-band credential'   = 'out-of-band|fuori da Terraform'
  'No Terraform apply'       = 'terraform apply.*non|non.*terraform apply'
}

$failedDocumentationChecks = @(
  foreach ($entry in $requiredDocumentationPatterns.GetEnumerator()) {
    if ($readmeSource -notmatch $entry.Value) {
      $entry.Key
    }
  }
)

if ($failedDocumentationChecks.Count -gt 0) {
  throw "Entra README contract checks failed: $($failedDocumentationChecks -join ', ')"
}

Write-Output 'Entra Terraform static contract checks passed.'
