# Microsoft Entra primary OIDC for Helios Desk

Questo stack registra il piano di identità **primary** di Helios Desk in un singolo tenant Microsoft Entra ID. Crea due application registration e i relativi service principal:

- `Helios Desk API`, resource server single-tenant con access token v2, scope delegato `access_as_user` e app role `tickets.read`, `tickets.write`, `automation.execute`;
- `Helios Desk BFF`, client web confidenziale single-tenant con una callback HTTPS esatta, implicit grant disabilitato e accesso delegato alla API.

Lo stack non crea utenti o gruppi, non concede permessi Microsoft Graph e non esegue `terraform apply`.

## Contratto OIDC

Il BFF usa **Authorization Code + PKCE S256**. La web platform Entra abilita il code flow e disabilita entrambi gli implicit grant; PKCE non ha un flag di enforcement nell'application registration, quindi il BFF deve sempre inviare `code_challenge_method=S256`, conservare il `code_verifier` lato server e verificare `state` e `nonce`. Token e refresh token non devono arrivare al browser.

Il BFF richiede gli scope `openid profile email api://<API_CLIENT_ID>/access_as_user`. Lo scope `access_as_user` identifica il client delegato tramite il claim `scp`; l'autorizzazione dell'utente resta basata sul claim `roles` dell'**access token API**, non sull'ID token del BFF.

### Audience v2: usare il GUID, non l'Application ID URI

Microsoft specifica che per gli access token v2 il claim `aud` è il **client ID GUID della Web API**. `api://<API_CLIENT_ID>` è l'identifier URI usato nella richiesta dello scope, ma non è l'audience operativa da validare.

Usare quindi:

```text
OIDC_AUDIENCE = terraform output -raw api_audience
OIDC_ROLES_CLAIM = roles
```

Il realm **Keycloak DR deve usare lo stesso GUID** restituito da `api_audience` sia come audience emessa sia come audience validata. Il valore storico `api://reverse-dr-helpdesk` non è equivalente al contratto Entra v2 e va sostituito durante il provisioning del realm DR; questo stack, per separazione di responsabilità, non modifica i file Keycloak.

Riferimenti: [validazione dei claim Microsoft](https://learn.microsoft.com/en-us/entra/identity-platform/claims-validation), [manifest e requestedAccessTokenVersion](https://learn.microsoft.com/en-us/entra/identity-platform/reference-app-manifest), [provider AzureAD](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs).

## Ruoli e consenso minimo

`app_role_assignment_required = true` sul service principal API rende l'accesso fail-closed. `role_assignments` è vuoto per default; ogni entry assegna uno dei tre ruoli a un object ID esplicito di utente, gruppo o service principal. Preferire gruppi di sicurezza gestiti e separare `automation.execute` dai ruoli ticket.

La BFF application dichiara soltanto lo scope delegato interno `access_as_user`. Lo stack non crea un `azuread_service_principal_delegated_permission_grant`: quel grant darebbe consenso tenant-wide e richiederebbe privilegi `Directory.ReadWrite.All`. Un amministratore deve approvare lo scope con il normale workflow di admin consent dopo aver verificato app, callback e assegnazioni.

Permessi minimi del principal che esegue Terraform:

- `Application.ReadWrite.OwnedBy` per application registration e service principal; il caller viene aggiunto come owner;
- soltanto quando `role_assignments` non è vuoto, `AppRoleAssignment.ReadWrite.All` insieme a `Application.Read.All` (oppure un ruolo directory equivalente autorizzato dalla policy tenant).

## Credenziale confidenziale del BFF

Terraform crea intenzionalmente solo il contenitore applicativo: non esiste alcun `azuread_application_password`, nessun secret compare in tfvars, output o state.

Per produzione, preferire una credenziale a certificato o una client assertion federata compatibile con il runtime. Caricare soltanto la chiave pubblica in Entra e custodire la chiave privata in un secret manager/HSM. Se il PoC richiede ancora `OIDC_CLIENT_SECRET`, generarlo **fuori da Terraform**, salvarlo direttamente nel secret manager del workload e non inserirlo mai in file `.tfvars`, variabili CLI, output o log. La BFF non può completare lo scambio del code finché una credenziale confidenziale non è stata provisionata out-of-band.

## Uso sicuro

Prerequisiti: Terraform `>= 1.10`, provider `hashicorp/azuread ~> 3.9`, tenant esistente e autenticazione AzureAD già configurata. Per CI preferire managed identity, workload identity federation o service principal con certificato; non committare credenziali.

```powershell
Set-Location automazione/infra/entra
Copy-Item terraform.tfvars.example terraform.tfvars
# Sostituire tenant, URI e object ID nel file locale non versionato.
terraform init
terraform fmt -check -recursive
terraform validate
terraform test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/static_contract.ps1
```

Questo repository prepara e valida la configurazione: **non eseguire `terraform apply`** senza change review, backend remoto cifrato/controllato e approvazione del tenant owner.

Gli output `oidc_runtime_config`, `api_audience`, `api_delegated_scope`, `api_app_role_ids`, `bff_client_id` e `tenant_id` contengono solo configurazione non segreta. `oidc_runtime_config` mappa direttamente le variabili runtime del BFF e dei resource server.
