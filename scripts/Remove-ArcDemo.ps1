<#
.SYNOPSIS
    Deletes the two demo resource groups and named subscription policy/budget.
.DESCRIPTION
    Explicit subscription/tenant required. -WhatIf makes no Azure changes.
    Defender subscription pricing is preserved unless -DisableDefender is passed.
    Identity deletion is separately opt-in; shared/ambiguous identities are refused.
    Successful completion means resource-group deletion was observed, not just submitted.
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
Assert-DemoName $NamePrefix
if ($KeepDefender -and $DisableDefender) { throw 'KeepDefender and DisableDefender cannot both be supplied.' }
Initialize-DemoContext $SubscriptionId $TenantId
$scope = "/subscriptions/$SubscriptionId"
$groups = @("rg-$NamePrefix", "rg-$NamePrefix-infra")
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", "Delete $($groups -join ', '), named policies and budget; identity deletion=$RemoveOnboardingIdentity; disable subscription Defender=$DisableDefender")) { return }
foreach ($name in "mcsb-$NamePrefix", "nist-$NamePrefix") {
    $assignment = Invoke-DemoAz -Arguments @('policy', 'assignment', 'show', '-n', $name, '--scope', $scope, '-o', 'json') -AllowNotFound
    if ($assignment) { Invoke-DemoAz -Arguments @('policy', 'assignment', 'delete', '-n', $name, '--scope', $scope) | Out-Null }
}
try {
    Invoke-AzRest -Method Delete -Url "https://management.azure.com$scope/providers/Microsoft.Consumption/budgets/budget-$NamePrefix`?api-version=2024-08-01" | Out-Null
} catch {
    if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
    Write-Verbose 'Demo budget already absent.'
}
if ($RemoveOnboardingIdentity) {
    $identities = @(Invoke-DemoAz -Arguments @('ad', 'sp', 'list', '--display-name', "sp-$NamePrefix-onboard", '-o', 'json') | ConvertFrom-Json |
        Where-Object displayName -eq "sp-$NamePrefix-onboard")
    if ($identities.Count -gt 1) { throw 'Onboarding identity name is ambiguous; refusing identity deletion.' }
    foreach ($identity in $identities) {
        $roles = @(Invoke-DemoAz -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $identity.id, '--all', '-o', 'json') | ConvertFrom-Json)
        if (@($roles | Where-Object { $_.scope -ne "$scope/resourceGroups/rg-$NamePrefix" }).Count) { throw 'Onboarding identity has permissions outside this demo; refusing to delete a potentially shared identity.' }
        Invoke-DemoAz -Arguments @('ad', 'sp', 'delete', '--id', $identity.id) | Out-Null
    }
}
foreach ($rg in $groups) {
    $exists = Invoke-DemoAz -Arguments @('group', 'exists', '-n', $rg, '-o', 'json') | ConvertFrom-Json
    if ($exists) { Invoke-DemoAz -Arguments @('group', 'delete', '-n', $rg, '--yes', '--no-wait') | Out-Null }
}
Wait-Until -TimeoutSeconds 1800 -IntervalSeconds 20 -Message 'both demo resource groups deleted' -Condition {
    foreach ($rg in $groups) {
        if (Invoke-DemoAz -Arguments @('group', 'exists', '-n', $rg, '-o', 'json') | ConvertFrom-Json) { return $false }
    }
    return $true
} | Out-Null
if ($DisableDefender) {
    Invoke-DemoAz -Arguments @('security', 'pricing', 'create', '--name', 'VirtualMachines', '--tier', 'Free', '-o', 'none') | Out-Null
}
Write-Ok 'Demo resource groups deleted. Defender pricing is preserved unless explicitly disabled; retained identities and soft-deleted Key Vaults may need separate review.'
