<#
.SYNOPSIS
    Parks retained demo workloads without deleting their data or resetting faults.
.DESCRIPTION
    Parks all compute in the explicitly targeted demo infra group, despite
    manifest/skin drift. Foreign/shared networking is warned about and untouched.
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
try { $skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot) }
catch {
    if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { throw 'Unreadable skin: supply the confirmed NamePrefix explicitly to park without it.' }
    Write-Warning "Skin ignored for parking: $($_.Exception.Message)"
}
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix -ForHibernation
try {
    $strict = Get-DemoInventory $NamePrefix
    Assert-DemoSkinInventory $skin $strict
    if (@($strict.Machines | Where-Object { -not $_.Actual }).Count) { throw 'Expected VMs are missing.' }
} catch { Write-Warning "Deployment/skin drift inspection: $($_.Exception.Message) Parking all compute in $($inventory.InfraRg), not starting or deleting it." }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Deallocate VMs, stop AKS, deactivate Container App revisions and remove demo NAT/public IP')) { return }
$infraRg = $inventory.InfraRg
foreach ($machine in $inventory.Machines) {
    try {
        if ($machine.Actual.powerState -notin @('VM deallocated', 'VM deallocating')) {
            Invoke-DemoAz -Arguments @('vm', 'deallocate', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
        }
    } catch { Write-Warning "VM parking failed: $($_.Exception.Message) Continuing other workloads; final power verification is mandatory." }
}
foreach ($id in $inventory.AksClusterIds) {
    try {
        $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
        if ($cluster.provisioningState -eq 'Stopping') { continue }
        if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS $($cluster.name) is $($cluster.provisioningState); cannot stop during another operation." }
        if ($cluster.powerState.code -ne 'Stopped') { Invoke-DemoAz -Arguments @('aks', 'stop', '-g', $infraRg, '-n', ($id -split '/')[-1], '--no-wait', '-o', 'none') | Out-Null }
    } catch { Write-Warning "AKS parking failed: $($_.Exception.Message) Continuing other workloads; final power verification is mandatory." }
}
foreach ($id in $inventory.ContainerAppIds) {
    $name = ($id -split '/')[-1]
    try { $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $infraRg, '-n', $name, '-o', 'json') | ConvertFrom-Json) }
    catch { Write-Warning "App inspection failed: $($_.Exception.Message)"; continue }
    foreach ($revision in $revisions | Where-Object { $_.properties.active }) {
        try { Invoke-DemoAz -Arguments @('containerapp', 'revision', 'deactivate', '-g', $infraRg, '--revision', $revision.name, '-o', 'none') | Out-Null }
        catch { Write-Warning "Revision parking failed: $($_.Exception.Message) Continuing other revisions; final verification is mandatory." }
    }
}
Wait-Until -Message 'all expected VMs deallocated and AKS stopped' -TimeoutSeconds 1200 -Condition {
    $current = Get-DemoInventory $NamePrefix -ForHibernation
    $checks = @(Get-DemoReadinessChecks -Inventory $current -NamePrefix $NamePrefix -DesiredState Hibernated | Where-Object required)
    if (@($checks | Where-Object status -eq 'fail').Count) { throw 'Compute state is unknown or unhealthy; inspect required cost-state checks.' }
    @($checks | Where-Object status -ne 'pass').Count -eq 0
} | Out-Null
try {
    $network = Get-DemoNetworkState -InfraRg $infraRg -NamePrefix $NamePrefix -ForHibernation
    if ($network.SafeToRemove) {
        if ($network.Subnet.natGateway.id -eq $network.NatId) {
            Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'update', '--ids', $network.Subnet.id, '--remove', 'natGateway', '-o', 'none') | Out-Null
        }
        if ($network.Nat) { Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'delete', '--ids', $network.NatId) | Out-Null }
        if ($network.PublicIp) { Invoke-DemoAz -Arguments @('network', 'public-ip', 'delete', '--ids', $network.PublicIpId) | Out-Null }
    } else { Write-Warning "NETWORK CLEANUP SKIPPED: $($network.ConflictMessage) NAT/PIP costs may remain; no foreign binding changed." }
} catch {
    Write-Warning "NETWORK CLEANUP INCOMPLETE: $($_.Exception.Message) Retained networking may still bill; retry cleanup separately."
}
& (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -DesiredState Hibernated -TimeoutSeconds 300
if ($LASTEXITCODE -ne 0) { throw 'Hibernated cost-state verification failed or inspection was denied; inspect required checks/errors above. Completed parking steps are preserved; retry remaining work without redeploying.' }
Write-Ok 'Compute parked. Review network cleanup diagnostics: skipped/failed NAT/PIP removal may still bill, as do retained disks, logs and enabled alerts. No fault flags or credentials changed.'
