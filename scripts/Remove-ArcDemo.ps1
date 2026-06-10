<#
.SYNOPSIS
    Removes the Arc demo deployment completely. Use this when you no longer
    need the demo and want to stop paying for it.

.DESCRIPTION
    Deletes:
      - Both resource groups (rg-<prefix> and rg-<prefix>-infra)
      - Subscription-scope policy assignments (MCSB + NIST)
      - Subscription-scope budget
      - The Arc onboarding service principal
      - (Optional) Reverts Defender for Servers to Free

.PARAMETER NamePrefix
    Used to derive RG / SPN / policy names (default: arc-demo).

.PARAMETER KeepDefender
    Don't revert Defender for Servers to Free. Useful if you have other VMs
    in the subscription that benefit from P2.

.PARAMETER WhatIf
    Preview deletions without performing them.

.EXAMPLE
    .\Remove-ArcDemo.ps1 -WhatIf
    .\Remove-ArcDemo.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NamePrefix = 'arc-demo',
    [switch]$KeepDefender
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force

$ctx = az account show --query "{id:id,user:user.name}" -o json | ConvertFrom-Json
$sub = $ctx.id

Write-Header "Removing Arc demo from subscription $sub"
Write-Step "Signed in as: $($ctx.user)"

$arcRg   = "rg-$NamePrefix"
$infraRg = "rg-$NamePrefix-infra"

Write-Step 'Removing policy assignments...'
foreach ($n in "mcsb-$NamePrefix", "nist-$NamePrefix") {
    $exists = az policy assignment show -n $n --scope "/subscriptions/$sub" --query id -o tsv 2>$null
    if ($exists -and $PSCmdlet.ShouldProcess($n, 'delete policy assignment')) {
        az policy assignment delete -n $n --scope "/subscriptions/$sub" --only-show-errors
        Write-Ok "Deleted $n"
    }
}

Write-Step 'Removing budget...'
if ($PSCmdlet.ShouldProcess("budget-$NamePrefix", 'delete budget')) {
    try {
        Invoke-AzRest -Method Delete -Url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Consumption/budgets/budget-$NamePrefix`?api-version=2024-08-01" | Out-Null
        Write-Ok "Deleted budget-$NamePrefix"
    } catch { Write-Warn "Budget delete: $($_.Exception.Message)" }
}

Write-Step 'Removing Arc onboarding service principal...'
$spnAppId = az ad sp list --display-name "sp-$NamePrefix-onboard" --query "[0].appId" -o tsv 2>$null
if ($spnAppId -and $PSCmdlet.ShouldProcess($spnAppId, 'delete SPN')) {
    az ad sp delete --id $spnAppId
    Write-Ok "Deleted SPN $spnAppId"
}

Write-Step 'Deleting resource groups (parallel)...'
foreach ($rg in $arcRg, $infraRg) {
    if (az group exists -n $rg) {
        if ($PSCmdlet.ShouldProcess($rg, 'delete resource group')) {
            az group delete -n $rg --yes --no-wait
            Write-Ok "Delete submitted for $rg"
        }
    } else {
        Write-Ok "$rg already gone"
    }
}

if (-not $KeepDefender) {
    Write-Step 'Reverting Defender for Servers to Free...'
    if ($PSCmdlet.ShouldProcess('VirtualMachines', 'set Defender Free')) {
        az security pricing create --name VirtualMachines --tier Free --only-show-errors -o tsv | Out-Null
        Write-Ok 'Defender for Servers reverted to Free'
    }
}

Write-Header '✅ Tear-down submitted. RG deletes finish in ~5-10 min.'
