<#
.SYNOPSIS
    Deletes the two demo resource groups and named subscription policy/budget.
.DESCRIPTION
    Explicit subscription/tenant required. -WhatIf makes no Azure changes.
    Defender subscription pricing is preserved unless -DisableDefender is passed.
    Identity deletion is separately opt-in; shared/ambiguous identities are refused.
    Successful completion verifies both groups and named policies/budget absent.
    Retained tenant identities, soft-deleted vaults and shared/subscription services
    are explicit exclusions, not a zero-bill or tenant-wide cleanup claim.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [switch]$KeepDefender,
    [switch]$DisableDefender,
    [switch]$RemoveOnboardingIdentity
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
$nestedSqlGuest = Get-DemoNestedSqlGuestConfig -Skin $skin
Assert-DemoName $NamePrefix
if ($KeepDefender -and $DisableDefender) { throw 'KeepDefender and DisableDefender cannot both be supplied.' }
Initialize-DemoContext $SubscriptionId $TenantId
$scope = "/subscriptions/$SubscriptionId"
$groups = @("rg-$NamePrefix", "rg-$NamePrefix-infra")
if ($RemoveOnboardingIdentity) {
    $identities = @(Invoke-DemoAz -Arguments @('ad', 'sp', 'list', '--display-name', "sp-$NamePrefix-onboard", '-o', 'json') | ConvertFrom-Json |
        Where-Object displayName -eq "sp-$NamePrefix-onboard")
    if ($identities.Count -gt 1) { throw 'Onboarding identity name is ambiguous; refusing identity deletion.' }
    foreach ($identity in $identities) {
        $roles = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $identity.id, '--all', '-o', 'json') | ConvertFrom-Json)
        if (@($roles | Where-Object { $_.scope -ne "$scope/resourceGroups/rg-$NamePrefix" }).Count) { throw 'Onboarding identity has permissions outside this demo; refusing to delete a potentially shared identity.' }
    }
}
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", "Delete $($groups -join ', '), named policies and budget; identity deletion=$RemoveOnboardingIdentity; disable subscription Defender=$DisableDefender")) { return }
if ($nestedSqlGuest) {
    $raw = Invoke-DemoAz -Arguments @('vm', 'show', '-d', '-g', "rg-$NamePrefix-infra", '-n', $nestedSqlGuest.ParentVmName, '-o', 'json') -AllowNotFound
    if ($raw) {
        $parent = $raw | ConvertFrom-Json
        $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix-infra/providers/Microsoft.Compute/virtualMachines/$($nestedSqlGuest.ParentVmName)"
        if ($parent.id -ne $expectedId -or $parent.storageProfile.osDisk.osType -ne 'Windows') { throw 'Configured nested SQL parent identity/OS is unexpected; refusing removal.' }
        if ($parent.powerState -eq 'VM running') {
            Invoke-DemoNestedSqlGuest -ParentMachine ([pscustomobject]@{ Name = $parent.name; Id = $parent.id; OsType = 'Windows' }) `
                -GuestVmName $nestedSqlGuest.GuestVmName -Action Stop
        } elseif ($parent.powerState -notin @('VM deallocated', 'VM deallocating')) {
            throw "Nested SQL parent is in $($parent.powerState); retry removal after the transition settles."
        }
    }
}
foreach ($name in "mcsb-$NamePrefix", "nist-$NamePrefix") {
    $assignment = Invoke-DemoAz -Arguments @('policy', 'assignment', 'show', '-n', $name, '--scope', $scope, '-o', 'json') -AllowNotFound
    if ($assignment) { Invoke-DemoAz -Arguments @('policy', 'assignment', 'delete', '-n', $name, '--scope', $scope) | Out-Null }
}
$budget = Invoke-DemoAz -Arguments @('consumption', 'budget', 'show', '--budget-name', "budget-$NamePrefix", '-o', 'json') -AllowNotFound
if ($budget) {
    try {
        Invoke-AzRest -Method Delete -Url "https://management.azure.com$scope/providers/Microsoft.Consumption/budgets/budget-$NamePrefix`?api-version=2024-08-01" | Out-Null
    } catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        Write-Verbose 'Demo budget already absent.'
    }
}
if ($RemoveOnboardingIdentity) {
    foreach ($identity in $identities) {
        Invoke-DemoAz -Arguments @('ad', 'sp', 'delete', '--id', $identity.id) | Out-Null
    }
}
foreach ($rg in $groups) {
    $exists = Invoke-DemoAz -Arguments @('group', 'exists', '-n', $rg, '-o', 'json') | ConvertFrom-Json
    if ($exists) { Invoke-DemoAz -Arguments @('group', 'delete', '-n', $rg, '--yes', '--no-wait') | Out-Null }
}
Wait-Until -TimeoutSeconds 1800 -IntervalSeconds 20 -Message 'demo groups, named policies and budget absent' -Condition {
    $checks = @(Get-DemoRemovalChecks -NamePrefix $NamePrefix)
    @($checks | Where-Object { $_.required -and $_.status -ne 'pass' }).Count -eq 0
} | Out-Null
if ($DisableDefender) {
    Invoke-DemoAz -Arguments @('security', 'pricing', 'create', '--name', 'VirtualMachines', '--tier', 'Free', '-o', 'none') | Out-Null
}
Write-Ok 'Removed: both demo groups and named policies/budget verified absent. Tenant identities/applications, soft-deleted vaults and shared/subscription services are explicitly excluded unless separately removed; no purge or zero-bill claim.'
