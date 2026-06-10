<#
.SYNOPSIS
    Puts the Arc demo into low-cost hibernation (~AUD 35/mo).

.DESCRIPTION
    - Deallocates all VMs in the infra RG.
    - Deletes the NAT Gateway and its public IP (saves ~AUD 55/mo).
    - Leaves Log Analytics, DCRs, workbook, alerts, Arc records and disks
      in place so the demo is intact and ready to wake up.

.PARAMETER NamePrefix
    Used to derive RG names (default: arc-demo).

.PARAMETER WhatIf
    Preview the actions without performing them.

.EXAMPLE
    .\Hibernate-ArcDemo.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NamePrefix = 'arc-demo'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"
$vnet    = "vnet-$NamePrefix"
$subnet  = 'snet-vms'
$natGw   = "natgw-$NamePrefix"
$natPip  = "pip-natgw-$NamePrefix"

Write-Header "Hibernating Arc demo ($arcRg + $infraRg)"

Write-Step 'Deallocating all VMs (parallel)...'
$vms = (az vm list -g $infraRg --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
if (-not $vms) { Write-Warn "No VMs found in $infraRg — nothing to deallocate"; return }
foreach ($v in $vms) {
    if ($PSCmdlet.ShouldProcess($v, 'deallocate')) {
        az vm deallocate -g $infraRg -n $v --no-wait --only-show-errors -o none
    }
}

Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'all VMs deallocated' -Condition {
    $running = (az vm list -g $infraRg --show-details --query "[?powerState=='VM running'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    return $running.Count -eq 0
} | Out-Null
Write-Ok 'All VMs deallocated'

# NAT GW must be deleted BEFORE the public IP (PIP delete fails if still allocated)
Write-Step 'Detaching + deleting NAT Gateway...'
$attached = az network vnet subnet show -g $infraRg --vnet-name $vnet -n $subnet --query "natGateway.id" -o tsv 2>$null
if ($attached -and $PSCmdlet.ShouldProcess('subnet', 'detach NAT GW')) {
    az network vnet subnet update -g $infraRg --vnet-name $vnet -n $subnet --remove natGateway --only-show-errors -o none
    Write-Ok 'Detached NAT GW from subnet'
}
$natExists = az network nat gateway show -g $infraRg -n $natGw --query id -o tsv 2>$null
if ($natExists -and $PSCmdlet.ShouldProcess($natGw, 'delete')) {
    az network nat gateway delete -g $infraRg -n $natGw --only-show-errors
    Write-Ok "Deleted $natGw"
}
$pipExists = az network public-ip show -g $infraRg -n $natPip --query id -o tsv 2>$null
if ($pipExists -and $PSCmdlet.ShouldProcess($natPip, 'delete')) {
    az network public-ip delete -g $infraRg -n $natPip --only-show-errors
    Write-Ok "Deleted $natPip"
}

Write-Header '✅ Demo hibernated'
Write-Host "  Steady-state hibernated cost: ~AUD 35/mo (OS disks + LAW retention)."
Write-Host "  Wake it up with: .\Activate-ArcDemo.ps1"
