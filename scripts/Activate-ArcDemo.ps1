<#
.SYNOPSIS
    Wakes the Arc demo from hibernation. Idempotent.

.DESCRIPTION
    - Recreates the NAT Gateway + public IP and attaches to the demo subnet.
    - Starts all VMs in parallel and waits until they're running.
    - Restarts the Arc agent (himds) and AMA on each VM so Connected status
      returns quickly without waiting for the default 5-min reconnect.
    - Validates Arc Connected + Heartbeat (unless -SkipValidate).

.PARAMETER NamePrefix
    Used to derive RG names (default: arc-demo).

.PARAMETER Location
    Azure region (must match the original deploy).

.PARAMETER SkipValidate
    Don't poll for Heartbeat at the end. Useful for prep-the-night-before runs.

.EXAMPLE
    .\Activate-ArcDemo.ps1
#>
[CmdletBinding()]
param(
    [string]$NamePrefix = 'arc-demo',
    [string]$Location = 'australiaeast',
    [switch]$SkipValidate
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"
$vnet    = "vnet-$NamePrefix"
$subnet  = 'snet-vms'
$natGw   = "natgw-$NamePrefix"
$natPip  = "pip-natgw-$NamePrefix"

Write-Header "Activating Arc demo ($arcRg + $infraRg)"

# 1. NAT GW (idempotent)
$pipExists = az network public-ip show -g $infraRg -n $natPip --query id -o tsv 2>$null
if (-not $pipExists) {
    az network public-ip create -g $infraRg -n $natPip -l $Location --sku Standard --allocation-method Static --only-show-errors -o none
    Write-Ok "Created public IP $natPip"
} else { Write-Ok "Public IP exists" }

$natExists = az network nat gateway show -g $infraRg -n $natGw --query id -o tsv 2>$null
if (-not $natExists) {
    az network nat gateway create -g $infraRg -n $natGw -l $Location --public-ip-addresses $natPip --idle-timeout 10 --only-show-errors -o none
    Write-Ok "Created NAT GW $natGw"
} else { Write-Ok "NAT GW exists" }

$attached = az network vnet subnet show -g $infraRg --vnet-name $vnet -n $subnet --query "natGateway.id" -o tsv 2>$null
if (-not $attached) {
    az network vnet subnet update -g $infraRg --vnet-name $vnet -n $subnet --nat-gateway $natGw --only-show-errors -o none
    Write-Ok 'Attached NAT GW to subnet'
} else { Write-Ok 'NAT GW already attached' }

# 2. Start VMs
Write-Step 'Starting all VMs (parallel)...'
$vms = (az vm list -g $infraRg --query "[].name" -o tsv) -split "`n" | Where-Object { $_ }
foreach ($v in $vms) { az vm start -g $infraRg -n $v --no-wait --only-show-errors -o none }
Wait-Until -TimeoutSeconds 600 -IntervalSeconds 20 -Message 'all VMs running' -Condition {
    $running = (az vm list -g $infraRg --show-details --query "[?powerState=='VM running'].name" -o tsv) -split "`n" | Where-Object { $_ }
    return $running.Count -eq $vms.Count
} | Out-Null
Write-Ok "$($vms.Count) VMs running"

# 3. Restart Arc + AMA so reconnect is fast
Write-Step 'Restarting Arc + AMA on each VM (parallel)...'
$winCmd = 'Restart-Service himds,AzureMonitorAgent -Force; "OK"'
$lnxCmd = 'sudo systemctl restart himdsd azuremonitoragent && echo OK'

$jobs = @()
foreach ($v in $vms) {
    $isWin = $v -like 'win-*'
    $jobs += Start-Job -Name "r-$v" -ScriptBlock {
        param($v, $rg, $isWin, $winCmd, $lnxCmd)
        $cmdId = if ($isWin) { 'RunPowerShellScript' } else { 'RunShellScript' }
        $script = if ($isWin) { $winCmd } else { $lnxCmd }
        az vm run-command invoke -g $rg -n $v --command-id $cmdId --scripts $script --query "value[0].message" -o tsv 2>&1
    } -ArgumentList $v, $infraRg, $isWin, $winCmd, $lnxCmd
}
$jobs | Wait-Job -Timeout 600 | Out-Null
foreach ($j in $jobs) {
    $out = (Receive-Job $j 2>&1 | Out-String).Trim()
    if ($out -match 'OK') { Write-Ok $j.Name } else { Write-Warn $j.Name }
    Remove-Job $j -Force
}

if ($SkipValidate) {
    Write-Header '✅ Activated (validation skipped)'
    return
}

# 4. Wait for Arc Connected
Write-Step 'Waiting for all Arc machines to report Connected...'
Wait-Until -TimeoutSeconds 600 -IntervalSeconds 30 -Message 'Arc Connected' -Condition {
    $c = (az connectedmachine list -g $arcRg --query "[?status=='Connected'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }
    return $c.Count -ge $vms.Count
} | Out-Null
Write-Ok 'All Arc machines Connected'

# 5. Heartbeat
Write-Step 'Waiting for Heartbeat from all hosts...'
$lawCustId = az monitor log-analytics workspace show -g $arcRg -n "law-$NamePrefix" --query customerId -o tsv 2>$null
Wait-Until -TimeoutSeconds 600 -IntervalSeconds 45 -Message 'Heartbeat' -Condition {
    $token = Get-LawQueryToken
    $hdr = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $body = @{ query = 'Heartbeat | where TimeGenerated > ago(10m) | summarize Hosts = dcount(Computer)' } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Method Post -Headers $hdr -Body $body -Uri "https://api.loganalytics.io/v1/workspaces/$lawCustId/query"
        $hosts = if ($r.tables[0].rows) { $r.tables[0].rows[0][0] } else { 0 }
        return $hosts -ge $vms.Count
    } catch { return $false }
} | Out-Null

Write-Header '✅ Demo is fully active'
Write-Host "  Open the workbook from the Arc resource group → Workbooks."
