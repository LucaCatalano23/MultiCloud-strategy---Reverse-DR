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

Write-Output 'Deployment contract passed.'
