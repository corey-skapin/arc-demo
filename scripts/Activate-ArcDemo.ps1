<#
.SYNOPSIS
    Restores outbound networking, starts retained workloads and validates the demo.
.DESCRIPTION
    Uses retained deployment manifests and actual VM OS metadata, not name prefixes.
    Does not reset workload faults or credentials. Patch assessment submission is
    asynchronous; readiness checks telemetry separately. -WhatIf is read-only.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [string]$NamePrefix = 'arc-demo',
    [string]$Location = 'australiaeast',
    [string]$SkinPath = '',
    [switch]$SkipValidate,
    [switch]$SkipPatchAssessment
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = Get-DemoSkinValue $skin 'azure.location' $Location }
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix
Assert-DemoSkinInventory $skin $inventory
$missing = @($inventory.Machines | Where-Object { -not $_.Actual })
if ($missing) { throw "Missing expected VMs: $($missing.Name -join ', '). Reconcile deployment before activation." }
if (-not $PSCmdlet.ShouldProcess("$SubscriptionId / $NamePrefix", 'Restore NAT, start VMs/AKS/Container Apps and submit patch assessments (without fault reset)')) { return }

$infraRg = $inventory.InfraRg
$natId = "/subscriptions/$SubscriptionId/resourceGroups/$infraRg/providers/Microsoft.Network/natGateways/natgw-$NamePrefix"
$pip = @($inventory.Resources | Where-Object { $_.type -eq 'Microsoft.Network/publicIPAddresses' -and $_.name -eq "pip-natgw-$NamePrefix" })
if (-not $pip) {
    Invoke-DemoAz -Arguments @('network', 'public-ip', 'create', '-g', $infraRg, '-n', "pip-natgw-$NamePrefix", '-l', $Location, '--sku', 'Standard', '--allocation-method', 'Static', '-o', 'none') | Out-Null
}
if ($natId -notin $inventory.Resources.id) {
    Invoke-DemoAz -Arguments @('network', 'nat', 'gateway', 'create', '-g', $infraRg, '-n', "natgw-$NamePrefix", '-l', $Location, '--public-ip-addresses', "pip-natgw-$NamePrefix", '--idle-timeout', '10', '-o', 'none') | Out-Null
}
$subnet = Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'show', '-g', $infraRg, '--vnet-name', "vnet-$NamePrefix", '-n', 'snet-vms', '-o', 'json') | ConvertFrom-Json
if ($subnet.natGateway.id -and $subnet.natGateway.id -ne $natId) { throw 'Demo subnet has an unexpected NAT Gateway; refusing to overwrite it.' }
if ($subnet.natGateway.id -ne $natId) {
    Invoke-DemoAz -Arguments @('network', 'vnet', 'subnet', 'update', '--ids', $subnet.id, '--nat-gateway', $natId, '-o', 'none') | Out-Null
}
$startedVmIds = @()
foreach ($machine in $inventory.Machines) {
    if ($machine.Actual.powerState -ne 'VM running') {
        Invoke-DemoAz -Arguments @('vm', 'start', '--ids', $machine.Id, '--no-wait', '-o', 'none') | Out-Null
        $startedVmIds += $machine.Id
    }
}
Wait-Until -Message 'expected VM identities running' -Condition {
    $vms = @(Invoke-DemoAz -Arguments @('vm', 'list', '-g', $infraRg, '--show-details', '-o', 'json') | ConvertFrom-Json)
    @($inventory.Machines | Where-Object { $_.Id -notin @($vms | Where-Object powerState -eq 'VM running' | ForEach-Object id) }).Count -eq 0
} | Out-Null

foreach ($id in $inventory.AksClusterIds) {
    $cluster = Invoke-DemoAz -Arguments @('aks', 'show', '-g', $infraRg, '-n', ($id -split '/')[-1], '-o', 'json') | ConvertFrom-Json
    if ($cluster.provisioningState -ne 'Succeeded') { throw "AKS $($cluster.name) is $($cluster.provisioningState). Wait for the current operation to finish, then retry; do not start during stop." }
    if ($cluster.powerState.code -eq 'Stopped') { Invoke-DemoAz -Arguments @('aks', 'start', '-g', $infraRg, '-n', ($id -split '/')[-1], '--no-wait', '-o', 'none') | Out-Null }
    elseif ($cluster.powerState.code -ne 'Running') { throw "Unexpected AKS power state: $($cluster.powerState.code)" }
}
foreach ($id in $inventory.ContainerAppIds) {
    $app = Invoke-DemoAz -Arguments @('containerapp', 'show', '--ids', $id, '-o', 'json') | ConvertFrom-Json
    $revisions = @(Invoke-DemoAz -Arguments @('containerapp', 'revision', 'list', '-g', $infraRg, '-n', $app.name, '-o', 'json') | ConvertFrom-Json)
    if (@($revisions | Where-Object { $_.properties.active }).Count -eq 0) {
        Invoke-DemoAz -Arguments @('containerapp', 'revision', 'activate', '-g', $infraRg, '--revision', $app.properties.latestRevisionName, '-o', 'none') | Out-Null
    }
}
$arcBeforeRestart = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
$reconnectIds = @()
foreach ($machine in $inventory.Machines) {
    $wasConnected = $machine.ArcId -in @($arcBeforeRestart | Where-Object status -eq 'Connected' | ForEach-Object id)
    if ($machine.Id -notin $startedVmIds -and ($machine.Native -or $wasConnected)) { continue }
    $reconnectIds += $machine.Id
    $services = @()
    if (-not $machine.Native) { $services += if ($machine.OsType -eq 'Windows') { 'himds' } else { 'himdsd' } }
    if ($machine.Monitor) { $services += if ($machine.OsType -eq 'Windows') { 'AzureMonitorAgent' } else { 'azuremonitoragent' } }
    if (-not $services) { continue }
    $script = if ($machine.OsType -eq 'Windows') {
        "`$ErrorActionPreference='Stop'; Restart-Service $($services -join ',') -Force; 'ARC_DEMO_OK'"
    } else { "set -e; sudo systemctl restart $($services -join ' '); echo ARC_DEMO_OK" }
    Invoke-DemoGuestCommand -Machine $machine -Script $script
}
Wait-Until -Message 'expected Arc identities connected' -Condition {
    $arc = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $inventory.ArcRg, '-o', 'json') | ConvertFrom-Json)
    @($inventory.Machines | Where-Object { -not $_.Native -and $_.ArcId -notin @($arc | Where-Object status -eq 'Connected' | ForEach-Object id) }).Count -eq 0
} | Out-Null
if (-not $SkipPatchAssessment -and $reconnectIds.Count -gt 0) {
    foreach ($machine in $inventory.Machines | Where-Object { -not $_.Native }) {
        Invoke-DemoAz -Arguments @('connectedmachine', 'assess-patches', '--ids', $machine.ArcId, '--no-wait', '-o', 'none') | Out-Null
    }
}
if (-not $SkipValidate) {
    & (Join-Path $PSScriptRoot 'Test-ArcDemoReadiness.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -NamePrefix $NamePrefix -SkinPath $SkinPath -TimeoutSeconds 600
    if ($LASTEXITCODE -ne 0) { throw 'Activation completed but readiness failed or remains pending. Review the readiness checks above.' }
}
Write-Ok 'Activation finished. Existing fault flags were preserved; assessment submissions are not assessment completion.'
