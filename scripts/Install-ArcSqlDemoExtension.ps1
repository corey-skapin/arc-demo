#Requires -Version 7.4
<#
.SYNOPSIS
    Installs the separately approved Arc SQL inventory extension using LicenseOnly.
.DESCRIPTION
    Run from the signed-in operator machine after Enable-NestedSqlDemoExtension.
    No manual SQL grants, PAYG, Defender, assessment, or backup enablement.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ArcName,
    [Parameter(Mandatory)][string]$Location
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Initialize-DemoContext $SubscriptionId $TenantId
$id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$ArcName"
$machine = Invoke-AzRest -Method Get -Url "https://management.azure.com${id}?api-version=2024-07-10"
if ($machine.properties.status -ne 'Connected' -or
    $machine.tags.ArcSQLServerExtensionDeployment -ne 'Disabled') {
    throw 'Arc machine must be Connected with automatic SQL deployment suppressed.'
}
$extensionUrl = "https://management.azure.com${id}/extensions/WindowsAgent.SqlServer?api-version=2024-07-10"
$existing = $null
try { $existing = Invoke-AzRest -Method Get -Url $extensionUrl }
catch {
    if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
}
if ($existing -and $existing.properties.provisioningState -eq 'Succeeded') {
    if ($existing.properties.settings.LicenseType -ne 'LicenseOnly') {
        throw 'Existing extension licensing differs; no automatic pricing change.'
    }
    $existing
    return
}
if (-not $PSCmdlet.ShouldProcess($id, 'Install approved LicenseOnly Arc SQL extension with default least privilege')) { return }
$body = @{
    location = $Location
    properties = @{
        publisher = 'Microsoft.AzureData'
        type = 'WindowsAgent.SqlServer'
        typeHandlerVersion = '1.1'
        autoUpgradeMinorVersion = $true
        enableAutomaticUpgrade = $true
        settings = @{
            SqlManagement = @{ IsEnabled = $true }
            LicenseType = 'LicenseOnly'
            ExcludedSqlInstances = @()
        }
    }
}
$null = Invoke-AzRest -Method Put -Url $extensionUrl -Body $body
Wait-Until -TimeoutSeconds 1800 -IntervalSeconds 20 -Message 'Arc SQL extension provisioning' -Condition {
    try { $extension = Invoke-AzRest -Method Get -Url $extensionUrl }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $false }
        throw
    }
    if ($extension.properties.provisioningState -in @('Failed','Canceled')) {
        throw "Arc SQL extension failed: $($extension.properties.instanceView.status.message)"
    }
    $extension.properties.provisioningState -eq 'Succeeded'
} | Out-Null
Invoke-AzRest -Method Get -Url $extensionUrl
