<#
.SYNOPSIS
    Parks retained demo workloads without deleting their data or resetting faults.
.DESCRIPTION
    Verifies exact VM deallocation and AKS Stopped state before removing NAT.
    Deactivates Container App revisions (minReplicas=0 alone is not a stopped app).
    Never run against a live demo without the operator's explicit approval.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix
Assert-DemoSkinInventory $skin $inventory
if (@($inventory.Machines | Where-Object { -not $_.Actual }).Count) { throw 'Expected VMs are missing; resolve inventory drift before hibernating.' }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Deallocate VMs, stop AKS, deactivate Container App revisions and remove demo NAT/public IP')) { return }
$infraRg = $inventory.InfraRg
foreach ($machine in $inventory.Machines) {
    if ($machine.Actual.powerState -ne 'VM deallocated') {
        Invoke-DemoAz -Arguments @('vm', 'deallocate', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
    }
}
foreach ($id in $inventory.AksClusterIds) {
    $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
    if ($cluster.provisioningState -eq 'Stopping') { continue }
    if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS $($cluster.name) is $($cluster.provisioningState). Resolve the in-progress/failed operation before parking." }
    if ($cluster.powerState.code -ne 'Stopped') { Invoke-DemoAz -Arguments @('aks', 'stop', '-g', $infraRg, '-n', ($id -split '/')[-1], '--no-wait', '-o', 'none') | Out-Null }
}
foreach ($id in $inventory.ContainerAppIds) {
    $name = ($id -split '/')[-1]
    $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $infraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json)
    foreach ($revision in $revisions | Where-Object { $_.properties.active }) {
        Invoke-DemoAz -Arguments @('containerapp', 'revision', 'deactivate', '-g', $infraRg, '--revision', $revision.name, '-o', 'none') | Out-Null
    }
}
Wait-Until -Message 'all expected VMs deallocated and AKS stopped' -TimeoutSeconds 1200 -Condition {
    $vms = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
    if (@($inventory.Machines | Where-Object { $_.Id -notin @($vms | Where-Object powerState -eq 'VM deallocated' | ForEach-Object id) }).Count) { return $false }
    foreach ($id in $inventory.AksClusterIds) {
        $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
        if ($cluster.powerState.code -ne 'Stopped' -or $cluster.provisioningState -ne 'Succeeded') { return $false }
    }
    return $true
} | Out-Null
$natId = "/subscriptions/$SubscriptionId/resourceGroups/$infraRg/providers/Microsoft.Network/natGateways/natgw-$NamePrefix"
$subnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '-g', $infraRg, '--vnet-name', "vnet-$NamePrefix", '-n', 'snet-vms', '-o', 'json') | ConvertFrom-Json
if ($subnet.natGateway.id -and $subnet.natGateway.id -ne $natId) { throw 'Unexpected subnet NAT Gateway; refusing to detach it.' }
if ($subnet.natGateway.id -eq $natId) {
    Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'update', '--ids', $subnet.id, '--remove', 'natGateway', '-o', 'none') | Out-Null
}
$resources = @(Invoke-DemoAz -Arguments @('resource', 'list', '-g', $infraRg, '-o', 'json') | ConvertFrom-Json)
if ($natId -in $resources.id) { Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'delete', '-g', $infraRg, '-n', "natgw-$NamePrefix") | Out-Null }
if ("pip-natgw-$NamePrefix" -in $resources.name) { Invoke-DemoAz -Arguments @('network', 'public-ip', 'delete', '-g', $infraRg, '-n', "pip-natgw-$NamePrefix") | Out-Null }
& (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -DesiredState Hibernated -TimeoutSeconds 300
if ($LASTEXITCODE -ne 0) { throw 'Hibernation is incomplete; inspect readiness output before retrying.' }
Write-Ok 'Demo hibernated. Disks, retained data, optional workload storage and subscription-level services can still incur charges.'
