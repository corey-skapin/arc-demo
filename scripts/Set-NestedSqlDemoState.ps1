#Requires -Version 7.4
<#
.SYNOPSIS
    Parks or wakes only the skin-configured nested guest and its parent.
.DESCRIPTION
    Uses the same Common helpers as Activate/Hibernate/Remove. Shared networking,
    other VMs, disks and credentials are retained. Use Activate-ArcDemo when
    whole-estate hibernation has removed outbound NAT.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('Running', 'Stopped')][string]$State,
    [string]$SkinPath = '',
    [string]$NamePrefix = 'arc-demo'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$guest = Get-DemoNestedSqlGuestConfig -Skin $skin
if (-not $guest) { throw 'Enable nestedSqlGuest in the private skin before changing its state.' }
Initialize-DemoContext $SubscriptionId $TenantId
$id = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix-infra/providers/Microsoft.Compute/virtualMachines/$($guest.ParentVmName)"
$parent = Invoke-DemoAz -Arguments @('vm', 'show', '--ids', $id, '--show-details', '-o', 'json') | ConvertFrom-Json
if ($parent.id -ne $id -or $parent.storageProfile.osDisk.osType -ne 'Windows' -or -not $parent.vmId) {
    throw 'Configured parent identity or Windows OS is unexpected.'
}
$parentVmId = $parent.vmId
if (-not $PSCmdlet.ShouldProcess($id, "Set configured guest $($guest.GuestVmName) and parent $State; retain shared networking")) { return }
if ($State -eq 'Running') {
    if ($parent.powerState -eq 'VM deallocated') {
        Invoke-DemoAz -Arguments @('vm', 'start', '--ids', $id, '-o', 'none') | Out-Null
    } elseif ($parent.powerState -notin @('VM running', 'VM starting')) { throw "Parent is $($parent.powerState); let its current transition settle." }
    Wait-Until -Message 'configured nested SQL parent running' -TimeoutSeconds 900 -Condition {
        $current = Invoke-DemoAz -Arguments @('vm', 'show', '--ids', $id, '--show-details', '-o', 'json') | ConvertFrom-Json
        $current.id -eq $id -and $current.vmId -eq $parentVmId -and $current.powerState -eq 'VM running'
    } | Out-Null
    Invoke-DemoNestedSqlGuest -ParentMachine ([pscustomobject]@{ Name = $guest.ParentVmName; Id = $id; OsType = 'Windows' }) `
        -GuestVmName $guest.GuestVmName -Action Start | Out-Null
    Wait-DemoNestedSqlArcConnected -ArcResourceGroup "rg-$NamePrefix" -ArcMachineName $guest.ArcMachineName
} else {
    if ($parent.powerState -eq 'VM running') {
        Invoke-DemoNestedSqlGuest -ParentMachine ([pscustomobject]@{ Name = $guest.ParentVmName; Id = $id; OsType = 'Windows' }) `
            -GuestVmName $guest.GuestVmName -Action Stop | Out-Null
        Invoke-DemoAz -Arguments @('vm', 'deallocate', '--ids', $id, '-o', 'none') | Out-Null
    } elseif ($parent.powerState -notin @('VM deallocated', 'VM deallocating')) { throw "Parent is $($parent.powerState); no unverified guest shutdown." }
}
$expected = if ($State -eq 'Running') { 'VM running' } else { 'VM deallocated' }
Wait-Until -Message "configured nested SQL parent $expected" -TimeoutSeconds 900 -Condition {
    $current = Invoke-DemoAz -Arguments @('vm', 'show', '--ids', $id, '--show-details', '-o', 'json') | ConvertFrom-Json
    $current.id -eq $id -and $current.vmId -eq $parentVmId -and $current.powerState -eq $expected
} | Out-Null
[pscustomobject]@{ ParentVm = $guest.ParentVmName; ParentVmId = $parentVmId; Power = $expected
    Guest = $guest.GuestVmName; RequestedGuestState = $State; SqlReadiness = 'check separately' }
