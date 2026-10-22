<#
.SYNOPSIS
    Read-only, machine-readable readiness for the retained Arc demo estate.
.DESCRIPTION
    JSON schemaVersion 1. Exit 0: required checks pass; 1: fail/error;
    2: eventual-consistency checks remain pending at the bounded deadline.
    Never repairs, induces faults, changes context defaults or registers providers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [ValidateSet('Active', 'Ready', 'Hibernated', 'Removed')][string]$DesiredState = 'Ready',
    [ValidateSet('Json', 'Table')][string]$OutputFormat = 'Table',
    [ValidateRange(0, 600)][int]$TimeoutSeconds = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
try {
    $skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
    Assert-DemoName $NamePrefix
    Initialize-DemoContext $SubscriptionId $TenantId
    do {
        $checks = if ($DesiredState -eq 'Removed') {
            @(Get-DemoRemovalChecks -NamePrefix $NamePrefix)
        } else {
            $inventory = Get-DemoInventory $NamePrefix
            Assert-DemoSkinInventory $skin $inventory
            @(Get-DemoReadinessChecks -Inventory $inventory -NamePrefix $NamePrefix -DesiredState $DesiredState)
        }
        $status = if (@($checks | Where-Object { $_.required -and $_.status -eq 'fail' }).Count) { 'fail' }
            elseif (@($checks | Where-Object { $_.required -and $_.status -eq 'pending' }).Count) { 'pending' }
            else { 'pass' }
        if ($status -ne 'pending' -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalSeconds)))
    } while ([DateTime]::UtcNow -lt $deadline)
} catch {
    $status = 'fail'
    $checks = @($checks) + @(New-DemoCheck 'readiness/error' '' 'successful read-only inspection' $null 'fail' -Message $_.Exception.Message)
}
$result = [ordered]@{
    schemaVersion = 1; workload = 'arc-demo'; checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"
    resourceGroups = @("rg-$NamePrefix", "rg-$NamePrefix-infra")
    desiredState = $DesiredState; status = $status; checks = @($checks | Where-Object { $_ })
}
if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 15 }
else {
    Write-Output "$DesiredState status: $status (required checks determine lifecycle state; non-required checks are diagnostics/exceptions)"
    $result.checks | Format-Table id, required, status, expected, observed, message -AutoSize
}
if ($status -eq 'pass') { exit 0 }
if ($status -eq 'pending') { exit 2 }
exit 1
