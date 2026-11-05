<#
.SYNOPSIS
    Deletes the two demo resource groups and named subscription policy/budget.
.DESCRIPTION
    Explicit subscription/tenant required. -WhatIf makes no Azure changes.
    Defender subscription pricing is preserved unless -DisableDefender is passed.
    Identity deletion is separately opt-in; shared/ambiguous identities are refused. It deletes the
    service principal only: the application registration, and any credential left on it (for example
    the one-year credential an older Deploy added when it created the application), stays, and removing
    that credential is the owner's decision (az ad app credential delete).
    A running nested SQL parent gets one bounded graceful guest stop; if that fails the
    removal warns and continues, because the parent and its guest are deleted anyway.
    -ForceDeleteWorkspace first permanently deletes the Log Analytics workspace; without it
    the workspace is only soft-deleted for 14 days and re-creating the same name recovers its old data.
    -PruneDeploymentHistory deletes this demo's own Deploy-ArcDemo subscription deployment
    records after removal is verified; policy, SRE and other deployment records are never touched.
    Successful completion verifies both groups and named policies/budget absent. Group deletion is
    slow when a Container Apps environment is present (it sits in ScheduledForDelete for about 25
    minutes), so a Remove normally takes 25-35 minutes. The wait lasts -TimeoutMinutes (default 60,
    at most 120) and names what is still present. If it ends first, the deletion simply goes on in Azure: the
    script exits 2 (pending, not failed), skips the steps that need verified removal, and a rerun
    with the same switches finishes them once the groups are gone.
    Exit codes: 0 removed and verified; 1 error; 2 deletion still in progress.
    Retained tenant identities, soft-deleted vaults and shared/subscription services
    are not deleted by this command and may still incur costs.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [switch]$KeepDefender,
    [switch]$DisableDefender,
    [switch]$RemoveOnboardingIdentity,
    [switch]$ForceDeleteWorkspace,
    [switch]$PruneDeploymentHistory,
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 60
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
$deleteWorkspace = $ForceDeleteWorkspace -and $PSCmdlet.ShouldProcess("law-$NamePrefix in rg-$NamePrefix", 'Permanently delete the Log Analytics workspace and its data (force; skips the 14-day soft-delete recovery)')
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", "Delete $($groups -join ', '), named policies and budget; identity deletion=$RemoveOnboardingIdentity; disable subscription Defender=$DisableDefender; force-delete workspace=$ForceDeleteWorkspace; prune deployment history=$PruneDeploymentHistory")) { return }
if ($deleteWorkspace) {
    # Must run before the group delete: afterwards the workspace is only soft-deleted and has to be recovered before it can be forced.
    $workspace = Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '-g', "rg-$NamePrefix", '-n', "law-$NamePrefix", '-o', 'json') -AllowNotFound
    if ($workspace) {
        Invoke-DemoAz -Arguments @('monitor', 'log-analytics', 'workspace', 'delete', '-g', "rg-$NamePrefix", '-n', "law-$NamePrefix", '--force', 'true', '--yes') | Out-Null
        Write-Ok "Log Analytics workspace law-$NamePrefix permanently deleted"
    } else {
        Write-Step "Log Analytics workspace law-$NamePrefix is already absent"
    }
}
if ($nestedSqlGuest) {
    $raw = Invoke-DemoAz -Arguments @('vm', 'show', '-d', '-g', "rg-$NamePrefix-infra", '-n', $nestedSqlGuest.ParentVmName, '-o', 'json') -AllowNotFound
    if ($raw) {
        $parent = $raw | ConvertFrom-Json
        $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix-infra/providers/Microsoft.Compute/virtualMachines/$($nestedSqlGuest.ParentVmName)"
        if ($parent.id -ne $expectedId -or $parent.storageProfile.osDisk.osType -ne 'Windows') { throw 'Configured nested SQL parent identity/OS is unexpected; refusing removal.' }
        if ($parent.powerState -eq 'VM running') {
            # The graceful stop is a courtesy for the guest's data: the parent, its disks and the guest are deleted with the group anyway.
            # A guest that never became an Arc machine has no data worth waiting a Run Command round trip for.
            $guestArc = Invoke-DemoAz -Arguments @('connectedmachine', 'show', '-g', "rg-$NamePrefix", '-n', $nestedSqlGuest.ArcMachineName, '-o', 'json') -AllowNotFound
            if (-not $guestArc) {
                Write-Step "The nested guest $($nestedSqlGuest.ArcMachineName) was never an Arc machine, so there is nothing to stop gracefully; skipping the guest command."
            } else {
                try {
                    Invoke-DemoNestedSqlGuest -ParentMachine ([pscustomobject]@{ Name = $parent.name; Id = $parent.id; OsType = 'Windows' }) `
                        -GuestVmName $nestedSqlGuest.GuestVmName -Action Stop -AllowAbsent -TimeoutSeconds 600
                } catch {
                    Write-Warn "Nested SQL guest did not stop gracefully ($($_.Exception.Message)). Continuing: the parent VM, its disks and the guest are deleted with rg-$NamePrefix-infra anyway."
                }
            }
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
$progress = @{ Pending = '' }
$removed = Wait-Until -TimeoutSeconds ($TimeoutMinutes * 60) -IntervalSeconds 20 -AllowTimeout -Message 'demo groups, named policies and budget absent' -Condition {
    $checks = @(Get-DemoRemovalChecks -NamePrefix $NamePrefix)
    $open = @($checks | Where-Object { $_.required -and $_.status -ne 'pass' })
    $names = ($open | ForEach-Object { $_.id }) -join ', '
    if ($names -and $names -ne $progress.Pending) { Write-Step "Still present: $names" }
    $progress.Pending = $names
    $open.Count -eq 0
}
if ($removed -eq $false) {
    Write-Warn "Deletion is still in progress after $TimeoutMinutes minutes (still present: $($progress.Pending)). Azure keeps deleting; nothing was retried or changed. Check with Test-ArcDemoReadiness.ps1 -DesiredState Removed (exit 2 while pending, 0 when removed), or rerun this command with the same switches once it is gone: it deletes nothing that is already absent, then finishes the verified-removal steps (deployment-history prune, Defender)."
    exit 2
}
if ($PruneDeploymentHistory) {
    $manifests = Get-DemoStaleManifestDeployments -Deployments @(Invoke-DemoAz -Arguments @('deployment', 'sub', 'list', '-o', 'json') | ConvertFrom-Json) -ArcResourceGroup "rg-$NamePrefix"
    foreach ($manifest in $manifests) {
        Invoke-DemoAz -Arguments @('deployment', 'sub', 'delete', '--name', $manifest.name) | Out-Null
    }
    Write-Ok "Pruned $(@($manifests).Count) Deploy-ArcDemo deployment record(s) for rg-$NamePrefix; no other deployment records were touched."
}
if ($DisableDefender) {
    Invoke-DemoAz -Arguments @('security', 'pricing', 'create', '--name', 'VirtualMachines', '--tier', 'Free', '-o', 'none') | Out-Null
}
Write-Ok 'Removed: both demo groups and named policies/budget verified absent. Tenant identities/applications, soft-deleted vaults and shared/subscription services remain unless separately removed; retained resources may still incur costs.'
