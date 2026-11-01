#Requires -Version 7.4
<#
.SYNOPSIS
    Removes one exact nested demo guest, its Arc machine and SQL instance.
.DESCRIPTION
    Does not remove the parent, shared NAT/switch, media, data volume or other VMs.
    Explicit Arc and Hyper-V identities are checked before any target deletion.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ParentResourceGroup,
    [Parameter(Mandatory)][string]$ParentVmName,
    [Parameter(Mandatory)][guid]$ParentVmId,
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][guid]$VmId,
    [Parameter(Mandatory)][string]$VmRoot,
    [Parameter(Mandatory)][string]$ArcMachineId,
    [Parameter(Mandatory)][guid]$ArcAgentVmId,
    [Parameter(Mandatory)][string]$SqlInstanceId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Initialize-DemoContext $SubscriptionId $TenantId
$prefix="/subscriptions/$SubscriptionId/resourceGroups/"
if (-not $ArcMachineId.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
    $ArcMachineId -notmatch '\A/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.HybridCompute/machines/([^/]+)\z' -or
    $Matches[1] -ine $VmName) { throw 'Arc machine ID does not match the explicit subscription and guest name.' }
$groupId=$ArcMachineId.Substring(0,$ArcMachineId.IndexOf('/providers/',[StringComparison]::OrdinalIgnoreCase))
if ($SqlInstanceId -ine "$groupId/providers/Microsoft.AzureArcData/sqlServerInstances/$VmName") { throw 'SQL instance ID differs from the guest target.' }
function Get-RemovalResource {
    param([string]$Url)
    try { Invoke-AzRest -Method Get -Url $Url }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}
$machine=Get-RemovalResource "https://management.azure.com${ArcMachineId}?api-version=2024-07-10"
$sql=Get-RemovalResource "https://management.azure.com${SqlInstanceId}?api-version=2026-01-01"
if (($machine -and ($machine.id -ine $ArcMachineId -or $machine.properties.vmId -ne "$ArcAgentVmId")) -or
    ($sql -and ($sql.id -ine $SqlInstanceId -or $sql.properties.containerResourceId -ine $ArcMachineId))) {
    throw 'Arc machine identity or SQL container binding differs.'
}
$target=@{
    SubscriptionId=$SubscriptionId;TenantId=$TenantId;ParentResourceGroup=$ParentResourceGroup
    ParentVmName=$ParentVmName;ParentVmId=$ParentVmId
}
$guest=@{VmName=$VmName;VmId="$VmId";VmRoot=$VmRoot}
if (-not $PSCmdlet.ShouldProcess("$VmName / $VmId / $ArcMachineId / $SqlInstanceId",'Delete only this guest, its private disks and Arc registrations')) { return }
& (Join-Path $PSScriptRoot 'Invoke-NestedSqlDemoStep.ps1') @target -Step Remove -Parameters $guest -TimeoutSeconds 600 -Confirm:$false
foreach ($resource in @(
    @{Id=$SqlInstanceId;Api='2026-01-01'},
    @{Id=$ArcMachineId;Api='2024-07-10'}
)) {
    $url="https://management.azure.com$($resource.Id)?api-version=$($resource.Api)"
    if (-not (Get-RemovalResource $url)) { continue }
    $null=Invoke-AzRest -Method Delete -Url $url
    Wait-Until -TimeoutSeconds 300 -IntervalSeconds 10 -Message "Removal of $($resource.Id)" -Condition {
        try { $null=Invoke-AzRest -Method Get -Url $url; return $false }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $true }
            throw
        }
    } | Out-Null
}
if ((Get-RemovalResource "https://management.azure.com${ArcMachineId}?api-version=2024-07-10") -or
    (Get-RemovalResource "https://management.azure.com${SqlInstanceId}?api-version=2026-01-01")) {
    throw 'Final Arc machine and SQL instance absence not verified.'
}
[pscustomobject]@{Guest=$VmName;VmId=$VmId;ArcMachineRemoved=$true;SqlInstanceRemoved=$true}
