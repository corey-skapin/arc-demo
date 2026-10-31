#Requires -Version 7.4
<#
.SYNOPSIS
    Prepares or inspects a real SQL workload on one explicitly selected lab VM.
.DESCRIPTION
    Uses retained manifests and checked jobs, not the experimental Arc SQL path.
    All live actions, including Status, execute guest Run Command. Offline export
    and WhatIf never invoke the guest. No media download, reboot or cloud changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]$')][string]$MachineName,
    [ValidateSet('Install', 'Status', 'Start', 'Stop', 'Incident', 'ProtectArcSql')][string]$Action = 'Status',
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$MediaIsoPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$MediaSha256,
    [switch]$AcceptDeveloperLicenseTerms,
    [switch]$ArcSqlAutoConnectOptOutConfirmed,
    [string]$GuestScriptOutputPath,
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'

function New-SqlEngineGuestScript {
    param([string]$Source, [hashtable]$Parameters)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Source))
    $settings = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Parameters | ConvertTo-Json -Compress)))
    @'
$ErrorActionPreference = 'Stop'
$file = Join-Path $env:TEMP ('arc-sql-engine-' + [guid]::NewGuid().ToString() + '.ps1')
try {
    [IO.File]::WriteAllText($file, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SOURCE__')), [Text.UTF8Encoding]::new($false))
    $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SETTINGS__')) | ConvertFrom-Json
    $arguments = @{}
    foreach ($entry in $settings.PSObject.Properties) { $arguments[$entry.Name] = $entry.Value }
    & $file @arguments
} catch {
    $message = $_.Exception.Message
    'ARC_SQL_ERROR=' + (@{ message = $message.Substring(0, [Math]::Min(400, $message.Length)) } | ConvertTo-Json -Compress)
    throw
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}
'@.Replace('__SOURCE__', $encoded).Replace('__SETTINGS__', $settings)
}

if ($Action -eq 'Install' -and -not $WhatIfPreference -and -not $GuestScriptOutputPath -and
    (-not $AcceptDeveloperLicenseTerms -or -not $MediaIsoPath -or -not $MediaSha256)) {
    throw 'Install requires explicit Developer licence acceptance plus an approved guest-local SQL 2022 Developer ISO and SHA256; no download or implied acceptance.'
}
if ($Action -eq 'Install' -and -not $WhatIfPreference -and -not $GuestScriptOutputPath -and -not $ArcSqlAutoConnectOptOutConfirmed) {
    throw 'Install also requires explicit confirmation of a reviewed effective Arc SQL automatic-connection opt-out; no tag/extension policy changes are made here.'
}
if ($MediaIsoPath -and $MediaIsoPath -notmatch '^[A-Za-z]:\\[^"]+\.iso$') { throw 'MediaIsoPath must be an explicit guest-local ISO path.' }
if ($ResultPath -and -not (Test-Path -LiteralPath (Split-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath))) -PathType Container)) {
    throw 'ResultPath parent must already exist; use a private evidence directory.'
}
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\samples\sql-engine\SqlEngineDemo.ps1') -Raw
$parameters = @{ Action = $Action }
if ($Action -eq 'Install') {
    $parameters.MediaIsoPath = $MediaIsoPath
    $parameters.MediaSha256 = $MediaSha256
    $parameters.AcceptDeveloperLicenseTerms = [bool]$AcceptDeveloperLicenseTerms
    $parameters.ArcSqlAutoConnectOptOutConfirmed = [bool]$ArcSqlAutoConnectOptOutConfirmed
}
$guest = New-SqlEngineGuestScript $source $parameters
if ($GuestScriptOutputPath) {
    if ($PSCmdlet.ShouldProcess($GuestScriptOutputPath, 'Export SQL guest script offline; do not execute')) {
        Set-Content -LiteralPath $GuestScriptOutputPath -Value $guest -Encoding utf8
        [pscustomobject]@{ exported = $true; path = $GuestScriptOutputPath; executed = $false }
    }
    return
}
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix
Assert-DemoSkinInventory $skin $inventory
$targets = @($inventory.Machines | Where-Object Name -eq $MachineName)
if ($targets.Count -ne 1 -or $targets[0].Native -or $targets[0].OsType -ne 'Windows' -or
    -not $targets[0].Actual -or $targets[0].Actual.powerState -ne 'VM running' -or
    $targets[0].Actual.provisioningState -ne 'Succeeded' -or $targets[0].Actual.storageProfile.osDisk.osType -ne 'Windows') {
    throw 'SQL target must be one retained, running, Windows Arc-backed VM. No native/unknown VM, OS guess or automatic activation.'
}
$target = $targets[0]
if (-not $PSCmdlet.ShouldProcess($target.Id, "$Action SQL workload via one guest Run Command; no download/reboot/Arc SQL")) { return }
$path = [IO.Path]::GetTempFileName()
$job = $null
try {
    [IO.File]::WriteAllText($path, $guest, [Text.UTF8Encoding]::new($false))
    $job = Start-DemoAzJob -Arguments @('vm', 'run-command', 'invoke', '--ids', $target.Id,
        '--command-id', 'RunPowerShellScript', '--scripts', "@$path", '-o', 'json', '--only-show-errors')
    $timeout = if ($Action -eq 'Install') { 1500 } else { 300 }
    $raw = Receive-DemoJobs -Jobs @($job) -TimeoutSeconds $timeout -PassThru | ConvertFrom-Json
} finally { [IO.File]::Delete($path) }
$entries = @($raw.value | Where-Object { $_ })
$stdout = @($entries | Where-Object code -Match '^ComponentStatus/StdOut/succeeded$|^ProvisioningState/succeeded$' | ForEach-Object message) -join "`n"
if (-not $entries -or @($entries | Where-Object { $_.code -match 'failed|error' -or $_.level -eq 'Error' }).Count -or
    @($entries | Where-Object { $_.code -match '^ComponentStatus/StdErr/' -and $_.message }).Count -or
    $stdout -notmatch '(?m)^ARC_DEMO_OK\r?$') {
    $errorLines = @($stdout -split '\r?\n' | Where-Object { $_.StartsWith('ARC_SQL_ERROR=') })
    $detail = if ($errorLines.Count -eq 1) { ($errorLines[0].Substring('ARC_SQL_ERROR='.Length) | ConvertFrom-Json).message } else { 'No structured guest error was returned.' }
    throw "SQL guest operation failed/unknown on $MachineName`: $detail Preserve RunCommand/setup state before retrying. No automatic replay."
}
$lines = @($stdout -split '\r?\n' | Where-Object { $_.StartsWith('ARC_SQL_RESULT=') })
if ($lines.Count -ne 1) { throw 'SQL guest operation returned no unique structured query result; no success claim or retry.' }
$snapshot = $lines[0].Substring('ARC_SQL_RESULT='.Length) | ConvertFrom-Json
if ($snapshot.status -notin @('pass', 'pending', 'stopped', 'recovered', 'protected') -or $snapshot.instance -ne 'ARCDEMO' -or $snapshot.database -ne 'ArcDemoOrders' -or
    ($Action -eq 'ProtectArcSql' -and ($snapshot.status -ne 'protected' -or $snapshot.blockedType -ne 'Microsoft.AzureData/WindowsAgent.SqlServer' -or $snapshot.monitoringUnchanged -ne $true)) -or
    ($Action -eq 'Incident' -and ($snapshot.status -ne 'recovered' -or $snapshot.sqlErrorNumber -ne 1222 -or $snapshot.ownedSessionsRemaining -ne 0 -or $snapshot.ordersWorkerHealthy -ne $true))) {
    throw 'SQL guest query result does not match the owned workload contract; no success claim.'
}
$result = [pscustomobject]@{
    schemaVersion = 1; workload = 'arc-sql-engine'; resourceId = $target.ArcId
    vmResourceId = $target.Id; action = $Action; evidence = $snapshot
}
if ($ResultPath) { $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$result
