$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$violations = [System.Collections.Generic.List[string]]::new()

$trackedFiles = @(git -C $repositoryRoot ls-files)
$deletedTrackedFiles = @(git -C $repositoryRoot ls-files --deleted)

if (
    $trackedFiles -contains 'automazione/helpdesk-dr/config.env' -and
    $deletedTrackedFiles -notcontains 'automazione/helpdesk-dr/config.env'
) {
    $violations.Add('automazione/helpdesk-dr/config.env must not be tracked')
}

$manifestPaths = @(
    # helpdesk.yaml (monolite legacy) e' stato rimosso insieme all'applicazione:
    # resta il solo PostgreSQL condiviso, che ospita il database `helios`.
    Join-Path $repositoryRoot 'automazione/helpdesk-dr/manifests/kubernetes/base/postgres.yaml'
)

foreach ($manifestPath in $manifestPaths) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        continue
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifest -match '(?m)^stringData:\s*$') {
        $violations.Add("$manifestPath contains versioned Kubernetes stringData")
    }
    if ($manifest -match '(?m)^\s*value:\s*(test|helpdesk-password)\s*$') {
        $violations.Add("$manifestPath contains an inline credential")
    }
}

$publishScript = Join-Path $repositoryRoot 'automazione/helpdesk-dr/scripts/poc/publish-git-truth.sh'
if (Test-Path -LiteralPath $publishScript) {
    $publishSource = Get-Content -LiteralPath $publishScript -Raw
    if ($publishSource -match 'cp\s+"\$\{ROOT_DIR\}/config\.env"\s+"\$\{workdir\}/config\.env"') {
        $violations.Add('publish-git-truth.sh must not copy config.env into Git')
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output 'Security contract passed.'
