#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only parity check: the expected objects of a rebuild from main versus the live estate or a snapshot.
.DESCRIPTION
    Compares config\expected-inventory.json (names, types, counts, tags; {prefix} expanded) and the
    retained deployment manifest's fleet with a snapshot. With -SnapshotPath it is fully offline;
    otherwise it takes a fresh read-only snapshot. Run it while the estate is Active: parked estates
    have no NAT gateway. Exit 0 when every check passes, 1 otherwise. Nothing is repaired.
.PARAMETER Feature
    Optional parts that should exist: ContainerApps, NestedSql, RealSql, OperationalWorkbooks, Sre,
    SreAlertGrant. Omit it to derive ContainerApps and NestedSql from the skin.
.EXAMPLE
    .\Test-ArcDemoParity.ps1 -SubscriptionId <SUB> -TenantId <TENANT> -SkinPath <PRIVATE>\arc-skin.json -Feature RealSql,Sre -OutputFormat Table
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$SnapshotPath = '',
    [string]$ExpectedPath = '',
    [ValidateSet('ContainerApps', 'NestedSql', 'RealSql', 'OperationalWorkbooks', 'Sre', 'SreAlertGrant')][string[]]$Feature,
    [ValidateSet('Json', 'Table')][string]$OutputFormat = 'Table'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/EstateSnapshot.psm1') -Force

$skin = Get-DemoSkin -Path $SkinPath -RepoRoot $repoRoot
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$nested = Get-DemoNestedSqlGuestConfig -Skin $skin
if (-not $PSBoundParameters.ContainsKey('Feature')) {
    $Feature = @(
        if ([bool](Get-DemoSkinValue $skin 'workloads.deployContainerApps' $false)) { 'ContainerApps' }
        if ($nested) { 'NestedSql' }
    )
}
if (-not $ExpectedPath) { $ExpectedPath = Join-Path $repoRoot 'config/expected-inventory.json' }
$expected = Get-Content -LiteralPath $ExpectedPath -Raw | ConvertFrom-Json
if ($expected.schemaVersion -ne 1) { throw 'The expected-object list must have schemaVersion 1.' }
if ($SnapshotPath) {
    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    if ($snapshot.schemaVersion -ne 1 -or $snapshot.workload -ne 'arc-demo-inventory') { throw 'The snapshot is not an arc-demo inventory (schemaVersion 1).' }
    if ($snapshot.subscriptionId -ne "$SubscriptionId" -or $snapshot.tenantId -ne "$TenantId" -or $snapshot.namePrefix -ne $NamePrefix) {
        throw 'The snapshot belongs to a different subscription, tenant or prefix than the explicit target.'
    }
} else {
    $snapshot = Get-DemoEstateSnapshot -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix | ConvertTo-Json -Depth 14 | ConvertFrom-Json
}
$parity = Test-DemoEstateParity -Snapshot $snapshot -Expected $expected -NamePrefix $NamePrefix -Feature $Feature `
    -NestedParentVmName $(if ($nested) { $nested.ParentVmName } else { '' }) -NestedArcMachineName $(if ($nested) { $nested.ArcMachineName } else { '' }) `
    -KeepParkedVmNames @(Get-DemoSkinValue $skin 'operations.keepParkedVmNames' @())
$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo-parity'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; namePrefix = $NamePrefix
    snapshotSource = $(if ($SnapshotPath) { 'file' } else { 'live' }); snapshotCapturedAtUtc = [string]$snapshot.capturedAtUtc
    features = @($Feature); status = $parity.status; checks = @($parity.checks)
}
if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 10 }
else {
    Write-Output "Parity status: $($result.status) ($(@($parity.checks | Where-Object status -eq 'fail').Count) of $(@($parity.checks).Count) checks failed; features: $(@($Feature) -join ', '))"
    $parity.checks | Format-Table id, status, expected, observed, message -AutoSize
}
if ($parity.status -eq 'pass') { exit 0 }
exit 1
