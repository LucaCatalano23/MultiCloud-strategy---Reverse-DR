$ErrorActionPreference = 'Stop'

$automazioneRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$contractPath = Join-Path $automazioneRoot 'contracts/deployment-contract.json'
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json

if ($contract.schemaVersion -ne 1) {
    throw 'Unsupported deployment contract version.'
}
if ($contract.application.publicApiBasePath -ne '/api/v1') {
    throw 'The public API base path must stay /api/v1.'
}
if ($contract.sites.dr.promotionOrchestrator -ne 'ansible') {
    throw 'Ansible must remain the on-prem promotion orchestrator.'
}

$expectedWorkloads = @(
    'helios-web',
    'helios-bff',
    'helios-ticket-service',
    'helios-automation-service'
)
$actualWorkloads = @($contract.kubernetes.workloads | ForEach-Object { $_.name })
foreach ($workload in $expectedWorkloads) {
    if ($actualWorkloads -notcontains $workload) {
        throw "Deployment contract is missing $workload."
    }
}

$onPremManifestPath = Join-Path $automazioneRoot 'infra/onprem/application/workloads.yaml'
if (Test-Path -LiteralPath $onPremManifestPath) {
    $onPremManifest = Get-Content -LiteralPath $onPremManifestPath -Raw
    foreach ($workload in $expectedWorkloads) {
        if ($onPremManifest -notmatch [regex]::Escape("name: $workload")) {
            throw "On-prem manifest is missing $workload."
        }
    }
}

$promotePath = Join-Path $automazioneRoot 'helpdesk-dr/scripts/failover/promote-onprem.sh'
if (Test-Path -LiteralPath $promotePath) {
    $promote = Get-Content -LiteralPath $promotePath -Raw
    foreach ($workload in $expectedWorkloads) {
        if ($promote -notmatch [regex]::Escape($workload)) {
            throw "Promotion script is missing $workload."
        }
    }
}

# La function `helpdesk-ticket-processor` esiste in due copie per necessita':
# immagine container su AWS, ConfigMap versionato su lambda-dr (Kustomize non
# puo' generare un ConfigMap da un file fuori dalla propria root). Se le due
# copie divergono, la PoC non dimostra piu' "stessa function su due runtime" ma
# due function diverse, quindi la divergenza e' un errore di contratto.
$functionSourcePath = Join-Path $automazioneRoot 'apps/functions/ticket-processor/handler.py'
$functionManifestPath = Join-Path $automazioneRoot 'lambda-dr/kubernetes/helpdesk-ticket-processor.yaml'
if ((Test-Path -LiteralPath $functionSourcePath) -and (Test-Path -LiteralPath $functionManifestPath)) {
    $manifestLines = Get-Content -LiteralPath $functionManifestPath
    $beginIndex = [Array]::IndexOf($manifestLines, '  handler.py: |')
    if ($beginIndex -lt 0) {
        throw 'The lambda-dr ConfigMap no longer embeds handler.py.'
    }

    $embedded = [System.Collections.Generic.List[string]]::new()
    for ($index = $beginIndex + 1; $index -lt $manifestLines.Length; $index++) {
        if ($manifestLines[$index] -eq '---') { break }
        $line = $manifestLines[$index]
        # Le righe vuote nel blocco YAML non portano indentazione.
        if ($line.Length -eq 0) { $embedded.Add('') } else { $embedded.Add($line.Substring(4)) }
    }

    $expected = @(Get-Content -LiteralPath $functionSourcePath | ForEach-Object { $_.TrimEnd() })
    $actual = @($embedded | ForEach-Object { $_.TrimEnd() })
    while ($actual.Count -gt 0 -and $actual[$actual.Count - 1] -eq '') {
        $actual = $actual[0..($actual.Count - 2)]
    }
    while ($expected.Count -gt 0 -and $expected[$expected.Count - 1] -eq '') {
        $expected = $expected[0..($expected.Count - 2)]
    }

    if (($expected -join "`n") -ne ($actual -join "`n")) {
        throw ('The lambda-dr ConfigMap copy of the ticket-processor function diverged from ' +
            'apps/functions/ticket-processor/handler.py. Run ' +
            '`python automazione/apps/functions/ticket-processor/sync-onprem-configmap.py`.')
    }
}

# Le metriche DR mostrate in dashboard devono avere due produttori reali: senza
# di essi l'endpoint /platform/status tornerebbe a esporre valori dichiarati a
# mano, che e' esattamente cio' che questa modifica ha rimosso.
$backupCronPath = Join-Path $automazioneRoot 'infra/aws/kubernetes/backup-cronjob.yaml'
if (Test-Path -LiteralPath $backupCronPath) {
    $backupCron = Get-Content -LiteralPath $backupCronPath -Raw
    if ($backupCron -notmatch "backup\.last_success") {
        throw 'The backup CronJob must publish the backup.last_success DR metric.'
    }
}

$failoverPlaybookPath = Join-Path $automazioneRoot 'helpdesk-dr/ansible/playbooks/failover.yml'
if (Test-Path -LiteralPath $failoverPlaybookPath) {
    $failoverPlaybook = Get-Content -LiteralPath $failoverPlaybookPath -Raw
    if ($failoverPlaybook -notmatch "failover\.last_promotion") {
        throw 'The failover playbook must publish the failover.last_promotion DR metric.'
    }
}

# Il monolite `helpdesk-api` e' stato rimosso di proposito (CLAUDE.md §1). Un
# reintroduzione accidentale - tipicamente ripescando un file da git history -
# riporterebbe la PoC ad avere due applicazioni concorrenti sullo stesso host DNS.
$removedLegacyPaths = @(
    'helpdesk-dr/app',
    'helpdesk-dr/manifests/kubernetes/base/helpdesk.yaml',
    'helpdesk-dr/manifests/kubernetes/cloud',
    'helpdesk-dr/scripts/deploy/deploy-cloud-primary.sh',
    'helpdesk-dr/scripts/deploy/build-helpdesk-image.sh'
)
foreach ($legacyPath in $removedLegacyPaths) {
    if (Test-Path -LiteralPath (Join-Path $automazioneRoot $legacyPath)) {
        throw "The legacy helpdesk-api monolith reappeared at $legacyPath."
    }
}

# Gli script DR condivisi non devono tornare a pilotare il monolite.
$drScriptPaths = @(
    'helpdesk-dr/scripts/common/lib.sh',
    'helpdesk-dr/scripts/failover/promote-onprem.sh',
    'helpdesk-dr/scripts/failover/demote-onprem.sh',
    'helpdesk-dr/scripts/restore/restore-onprem.sh',
    'helpdesk-dr/scripts/deploy/deploy-onprem-standby.sh'
)
foreach ($scriptPath in $drScriptPaths) {
    $fullPath = Join-Path $automazioneRoot $scriptPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Missing DR orchestration script $scriptPath."
    }
    if ((Get-Content -LiteralPath $fullPath -Raw) -match 'deployment/helpdesk-api') {
        throw "$scriptPath still drives the removed helpdesk-api monolith."
    }
}

# I segreti sono il terzo piano con provider diverso per sito, come identita' e
# automazione. Il meccanismo di consumo deve pero' restare UNO: se i due siti
# divergessero anche sul consumo, i manifest dei workload dovrebbero conoscere
# il sito, che e' esattamente cio' che questa architettura evita.
if ($contract.secrets.consumption -ne 'external-secrets-operator') {
    throw 'Both sites must consume secrets through External Secrets Operator.'
}
if ($contract.secrets.primary.backend -ne 'aws-secrets-manager') {
    throw 'The primary site must read secrets from AWS Secrets Manager.'
}
if ($contract.secrets.dr.backend -ne 'openbao') {
    throw 'The DR site must read secrets from OpenBao.'
}
# Un auto-unseal via KMS del cloud reintrodurrebbe una dipendenza dal sito
# caduto: il sigillo deve restare locale al sito DR.
if ($contract.secrets.dr.sealMode -ne 'shamir') {
    throw 'The DR vault must not depend on a cloud KMS to unseal.'
}
if ($contract.secrets.dr.autoUnseal -like '*kms*') {
    throw 'Auto-unseal must not delegate the seal authority to the primary site.'
}

# L'auto-unseal abbassa le garanzie del sigillo: deve restare un'attivazione
# deliberata. Se `install-openbao.sh` lo invocasse, diventerebbe un default
# silenzioso, che e' esattamente cio' che l'opt-in esplicito vuole impedire.
if ($contract.secrets.dr.autoUnsealActivation -ne 'explicit-opt-in') {
    throw 'Auto-unseal must stay an explicit opt-in.'
}
$installScript = Join-Path $automazioneRoot 'infra/vault/scripts/install-openbao.sh'
if (Test-Path -LiteralPath $installScript) {
    if ((Get-Content -LiteralPath $installScript -Raw) -match 'enable-auto-unseal') {
        throw 'install-openbao.sh must not enable auto-unseal implicitly.'
    }
}
$autoUnsealScript = Join-Path $automazioneRoot 'infra/vault/scripts/enable-auto-unseal.sh'
if (-not (Test-Path -LiteralPath $autoUnsealScript)) {
    throw 'The opt-in auto-unseal script is missing.'
}
if ((Get-Content -LiteralPath $autoUnsealScript -Raw) -notmatch 'OPENBAO_ACCEPT_AUTO_UNSEAL_RISK') {
    throw 'enable-auto-unseal.sh must require an explicit risk acknowledgement.'
}

foreach ($side in @('primary', 'dr')) {
    $manifestPath = Join-Path $automazioneRoot $contract.secrets.$side.manifest
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Missing External Secrets manifest for the $side site."
    }
}

# Ogni Secret dichiarato dal contratto deve avere un ExternalSecret che lo
# produca nel sito DR: un nome mancante qui significa un pod che non parte.
$drSecretsManifest = Get-Content -LiteralPath (
    Join-Path $automazioneRoot $contract.secrets.dr.manifest) -Raw
foreach ($reference in $contract.secrets.materializedSecrets) {
    $secretName = $reference.Split('/')[-1]
    if ($drSecretsManifest -notmatch [regex]::Escape("name: $secretName")) {
        throw "The DR site has no ExternalSecret producing $reference."
    }
}

# Il preflight del vault deve precedere lo switch DNS nel playbook, altrimenti
# si promuoverebbe un sito i cui pod non possono leggere le credenziali. Il
# preflight interroga `bao status` sul nodo vault (helios_vault_node): si
# verifica la presenza di entrambi, non una stringa di implementazione fragile.
if (Test-Path -LiteralPath $failoverPlaybookPath) {
    if ($failoverPlaybook -notmatch 'helios_vault_node' -or $failoverPlaybook -notmatch 'bao') {
        throw 'The failover playbook must verify OpenBao before promoting the DR site.'
    }
}

Write-Output 'Deployment contract passed.'
