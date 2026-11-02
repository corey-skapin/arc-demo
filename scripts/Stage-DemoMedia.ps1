#Requires -Version 7.4
<#
.SYNOPSIS
    Stages pinned Microsoft installer media on one lab Windows VM and verifies size and SHA-256.
.DESCRIPTION
    The media list (URL, bytes, SHA-256, licence URL) is config\demo-media.json. The download
    runs on the VM with curl.exe through classic Run Command (no managed-command slot), is
    resumable, and only a file that matches its pin takes the final name. An existing file
    that does not match is never overwritten, and a mismatching download is discarded.

    Every item needs its explicit terms switch. The acceptance (time, operator, terms URL,
    scope and pin) is recorded in a private file (default .local\media-acceptance.json) and is
    never implied. -WhatIf validates the request and resolves the target but runs nothing on
    the VM and writes nothing. The VM must already be running; this script never starts one.
.EXAMPLE
    .\scripts\Stage-DemoMedia.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -MachineName win-sql-01 `
        -Media sql-server-2022-developer -Destination C:\DemoMedia -AcceptSqlDeveloperTerms -SkinPath <PRIVATE_SKIN>
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$')][string]$MachineName,
    [Parameter(Mandatory)][string[]]$Media,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:\\[^"<>|?*]+$')][string]$Destination,
    [switch]$AcceptWindowsEvaluationTerms,
    [switch]$AcceptSqlDeveloperTerms,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$ManifestPath = '',
    [string]$AcceptanceRecordPath = '',
    [string]$ResultPath = '',
    [ValidateRange(300, 7200)][int]$TimeoutSeconds = 3600
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$repoRoot = Split-Path $PSScriptRoot

$manifest = @(Get-DemoMediaManifest -Path $ManifestPath -RepoRoot $repoRoot)
$items = @(foreach ($id in ($Media | Select-Object -Unique)) {
    $item = $manifest | Where-Object Id -eq $id
    if (-not $item) { throw "Unknown media '$id'. Known media: $($manifest.Id -join ', ')." }
    $item
})
$accepted = @{ AcceptWindowsEvaluationTerms = [bool]$AcceptWindowsEvaluationTerms; AcceptSqlDeveloperTerms = [bool]$AcceptSqlDeveloperTerms }
foreach ($item in $items) {
    if (-not $accepted[$item.AcceptanceSwitch] -and -not $WhatIfPreference) {
        throw "$($item.DisplayName) needs explicit terms acceptance: read $($item.LicenseUrl) (scope: $($item.Scope)), then add -$($item.AcceptanceSwitch). Acceptance is recorded, never implied."
    }
}
if ($ResultPath -and -not (Test-Path -LiteralPath (Split-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath))) -PathType Container)) {
    throw 'ResultPath parent must already exist; use a private evidence directory.'
}

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$target = (Get-DemoGuestTarget -NamePrefix $NamePrefix -Skin $skin -MachineName $MachineName).Target
if ($target.Actual.powerState -ne 'VM running' -or $target.Actual.provisioningState -ne 'Succeeded') {
    throw "$MachineName must be running and Succeeded before media is staged; this script never starts a VM. Run the approved Activate first."
}
$root = $Destination.TrimEnd('\')
$gib = [Math]::Round((($items | Measure-Object -Property Bytes -Sum).Sum) / 1GB, 2)
if (-not $PSCmdlet.ShouldProcess($target.Id, "Download $($items.Count) media file(s), about $gib GiB, to $root; verify size and SHA-256 before use")) { return }

$recordPath = if ($AcceptanceRecordPath) { $AcceptanceRecordPath } else { Join-Path $repoRoot '.local\media-acceptance.json' }
$record = [ordered]@{ schemaVersion = 1; items = [ordered]@{} }
if (Test-Path -LiteralPath $recordPath) {
    $existing = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable -Depth 6
    if ($existing -is [System.Collections.IDictionary] -and $existing.items -is [System.Collections.IDictionary]) { foreach ($key in $existing.items.Keys) { $record.items[$key] = $existing.items[$key] } }
}
$operator = ([string](Invoke-DemoAz -Arguments @('account', 'show', '--query', 'user.name', '-o', 'tsv') | Select-Object -First 1)).Trim()
foreach ($item in $items) {
    $previous = $record.items[$item.Id]
    if ($previous -is [System.Collections.IDictionary] -and $previous.sha256 -eq $item.Sha256) { continue }
    $record.items[$item.Id] = [ordered]@{
        acceptedAtUtc = [DateTime]::UtcNow.ToString('o'); acceptedBy = $operator; displayName = $item.DisplayName
        licenseUrl = $item.LicenseUrl; scope = $item.Scope; bytes = $item.Bytes; sha256 = $item.Sha256
    }
}
$null = New-Item -ItemType Directory -Path (Split-Path $recordPath) -Force
[System.IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

$settings = @{
    root = $root
    items = @($items | ForEach-Object { @{ id = $_.Id; fileName = $_.FileName; url = $_.Url; bytes = $_.Bytes; sha256 = $_.Sha256 } })
}
$guest = Invoke-DemoGuestAction -Machine $target -ScriptPath (Join-Path $PSScriptRoot 'guest\Save-DemoMedia.ps1') -Action Save -Settings $settings -TimeoutSeconds $TimeoutSeconds
$staged = foreach ($item in $items) {
    $saved = @($guest.items | Where-Object { $_.id -eq $item.Id })
    if ($saved.Count -ne 1 -or [int64]$saved[0].bytes -ne $item.Bytes -or ([string]$saved[0].sha256).ToUpperInvariant() -ne $item.Sha256 -or
        [string]$saved[0].path -ne "$root\$($item.FileName)") {
        throw "The guest result for $($item.Id) does not match its pin; do not use the file."
    }
    [pscustomobject]@{ id = $item.Id; path = [string]$saved[0].path; bytes = $item.Bytes; sha256 = $item.Sha256; state = [string]$saved[0].state }
}
$result = [pscustomobject]@{
    schemaVersion = 1; workload = 'demo-media'; machine = $MachineName; resourceId = $target.Id
    destination = $root; items = @($staged); acceptanceRecord = $recordPath
}
if ($ResultPath) { $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$result
