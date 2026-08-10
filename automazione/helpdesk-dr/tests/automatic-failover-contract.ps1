$ErrorActionPreference = 'Stop'

$moduleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-RequiredFile([string] $RelativePath) {
    $path = Join-Path $moduleRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing automatic failover artifact: $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Contains([string] $Text, [string] $Expected, [string] $Message) {
    if (-not $Text.Contains($Expected)) {
        throw $Message
    }
}

$unit = Read-RequiredFile 'systemd/helpdesk-dr-controller.service'
Assert-Contains $unit 'ExecStart=/usr/local/bin/helpdesk-dr failover/dr-controller watch' `
    'The service must start the supervised watch loop.'
Assert-Contains $unit 'Restart=always' 'The controller must restart after an unexpected exit.'
Assert-Contains $unit 'WantedBy=multi-user.target' 'The controller must start automatically at boot.'
Assert-Contains $unit 'ProtectSystem=strict' 'The privileged controller must have a read-only system filesystem.'

$bootstrap = Read-RequiredFile 'scripts/poc/bootstrap-ansible-control-node.sh'
Assert-Contains $bootstrap 'helpdesk-dr-controller.service' `
    'The coordinator bootstrap must install the controller unit.'
Assert-Contains $bootstrap 'systemctl enable --now helpdesk-dr-controller.service' `
    'The coordinator bootstrap must enable and start automatic failover.'
Assert-Contains $bootstrap 'failover/dr-controller validate' `
    'The coordinator bootstrap must validate an explicitly armed probe before starting the controller.'

$publisher = Read-RequiredFile 'scripts/poc/publish-git-truth.sh'
Assert-Contains $publisher 'systemd' 'The published DR source of truth must include systemd units.'

$defaults = Read-RequiredFile 'config.defaults'
Assert-Contains $defaults 'CLOUD_PROBE_MODE="lxc-k3s"' `
    'The lab must keep an explicit LXC probe mode.'
Assert-Contains $defaults 'CLOUD_TARGET_HOST=""' `
    'A real cloud deployment must expose a separate ALB target hostname.'
Assert-Contains $defaults 'CLOUD_HEALTHCHECK_PATH="/health/ready"' `
    'The ALB probe must use the BFF aggregate readiness endpoint.'
Assert-Contains $defaults 'DR_CONTROLLER_RETRY_COOLDOWN_SECONDS=' `
    'A failed promotion must have a retry cooldown.'
Assert-Contains $defaults 'DR_AUTO_FAILOVER_ENABLED="false"' `
    'Automatic promotion must be explicitly armed after selecting the cloud target.'
Assert-Contains $defaults 'BACKUP_MIRROR_RETENTION="2"' `
    'The on-prem backup mirror must default to keeping the two most-recent backups.'

$mirrorScript = Read-RequiredFile 'scripts/backup/mirror-from-s3.sh'
Assert-Contains $mirrorScript 'BACKUP_S3_BUCKET' `
    'The backup mirror must pull from the configured primary S3 bucket.'
Assert-Contains $mirrorScript 'sha256sum' `
    'The backup mirror must verify each downloaded backup by checksum.'
Assert-Contains $mirrorScript 'mirror left untouched' `
    'A failed S3 listing must never prune the mirror, so the last-good backup survives a cloud outage.'
Assert-Contains $mirrorScript 'BACKUP_MIRROR_RETENTION' `
    'The backup mirror must keep only the configured number of most-recent backups.'

$mirrorService = Read-RequiredFile 'systemd/helpdesk-dr-backup-mirror.service'
Assert-Contains $mirrorService 'ExecStart=/usr/local/bin/helpdesk-dr backup/mirror-from-s3' `
    'The mirror service must run the S3 sync through the dispatcher.'
Assert-Contains $mirrorService 'ReadWritePaths=/srv/helpdesk-dr-mirror' `
    'The hardened mirror service must be allowed to write only the mirror directory.'

$mirrorTimer = Read-RequiredFile 'systemd/helpdesk-dr-backup-mirror.timer'
Assert-Contains $mirrorTimer 'OnUnitActiveSec=2min' `
    'The cloud backup presence check must run every 2 minutes.'

Assert-Contains $bootstrap 'helpdesk-dr-backup-mirror.timer' `
    'The coordinator bootstrap must install the backup mirror timer.'

$library = Read-RequiredFile 'scripts/common/lib.sh'
Assert-Contains $library 'cloud_ready_https' 'The DR library must support a real HTTPS cloud probe.'
Assert-Contains $library 'cloud_ready_http' `
    'The DR library must support a plain-HTTP probe for an ALB without ACM.'
Assert-Contains $library '--connect-to' `
    'The cloud probe must preserve the canonical Host while connecting directly to the ALB.'
Assert-Contains $library 'CLOUD_TARGET_HOST' `
    'The cloud probe must target the ALB by a configurable hostname or IP.'
Assert-Contains $library 'CLOUD_TARGET_CA_FILE' `
    'The https probe must allow pinning a custom CA for a self-signed ALB certificate.'
Assert-Contains $library 'CLOUD_TARGET_INSECURE' `
    'The https probe must allow skipping verification for an untrusted ALB certificate.'
Assert-Contains $library "'%{http_code}'" `
    'The cloud probe must require an explicit HTTP status instead of accepting redirects.'
Assert-Contains $library 'wait_for_deployment_stopped' `
    'Restore and cutback must share a verified scale-to-zero barrier.'
if ($library.Contains('${ROOT_DIR}/.lab.zone') -or $library.Contains('${ROOT_DIR}/.helpdesk.zone')) {
    throw 'DNS temporary files must stay in RuntimeDirectory because /opt is read-only under systemd.'
}

$restore = Read-RequiredFile 'scripts/restore/restore-onprem.sh'
if ($restore.Contains('mktemp -d "${ROOT_DIR}/.restore.XXXXXX"')) {
    throw 'Restore temporary files must stay in RuntimeDirectory because /opt is read-only under systemd.'
}
Assert-Contains $restore 'Invalid PostgreSQL identifier' `
    'Database and role identifiers from runtime configuration must be allowlisted.'
Assert-Contains $restore 'wait_for_deployment_stopped' `
    'Restore must wait until all on-prem application pods have stopped.'

$cloudIngress = Read-RequiredFile '../infra/aws/kubernetes/ingress.yaml'
Assert-Contains $cloudIngress 'path: /health/ready' `
    'The public ALB must route aggregate readiness to the BFF before the frontend catch-all.'

$controller = Read-RequiredFile 'scripts/failover/dr-controller.sh'
Assert-Contains $controller 'validate_dr_controller_config' `
    'Controller thresholds and cloud target must fail fast when malformed.'
Assert-Contains $controller 'DR_CONTROLLER_RETRY_COOLDOWN_SECONDS' `
    'A failed failover must not create a tight retry loop.'
Assert-Contains $controller 'flock -n' 'The singleton controller lock must not remain stale.'

$runner = Read-RequiredFile 'scripts/failover/run-ansible-failover.sh'
Assert-Contains $runner 'flock -n' `
    'Manual and automatic failover must share an operation lock.'
Assert-Contains $runner 'write_dr_state "promoting"' `
    'Failover must persist an intermediate state before restore.'
Assert-Contains $runner 'write_dr_state "reconcile"' `
    'An ambiguous promotion failure must fail closed instead of being retried as primary.'

$promoter = Read-RequiredFile 'scripts/failover/promote-onprem.sh'
if ($promoter.Contains('write_dr_state')) {
    throw 'The failover wrapper must be the only owner of promotion state transitions.'
}

$demoter = Read-RequiredFile 'scripts/failover/demote-onprem.sh'
if ($demoter.Contains('write_dr_state')) {
    throw 'Demotion must not independently overwrite the state machine.'
}
if ($demoter.Contains('|| true')) {
    throw 'Demotion must propagate Kubernetes failures before cutback commits primary state.'
}
Assert-Contains $demoter 'Demotion verification failed' `
    'Cutback must verify the final on-prem replica and DR_ACTIVE state.'
Assert-Contains $demoter 'wait_for_deployment_stopped' `
    'Cutback must wait until all on-prem application pods have stopped.'

$standbyDeploy = Read-RequiredFile 'scripts/deploy/deploy-onprem-standby.sh'
Assert-Contains $standbyDeploy 'failover.lock' `
    'Standby deployment must not race with promotion or cutback state transitions.'

$runbook = Read-RequiredFile 'README.md'
Assert-Contains $runbook "status.loadBalancer.ingress[0].hostname" `
    'The runbook must show how to obtain the ALB hostname instead of asking for an IP.'

Write-Output 'Automatic failover contract passed.'
