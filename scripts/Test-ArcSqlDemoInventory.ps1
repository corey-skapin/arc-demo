#Requires -Version 7.4
<#
.SYNOPSIS
    Reads the Arc SQL extension, SQL instance and database inventory from Azure.
.DESCRIPTION
    Inventory may lag installation or wake. Does not install extensions, change
    permissions, enable features, or infer readiness from local service state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ArcName,
    [Parameter(Mandatory)][string]$SqlResourceName
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Initialize-DemoContext $SubscriptionId $TenantId
$group = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$machineId = "$group/providers/Microsoft.HybridCompute/machines/$ArcName"
$sqlId = "$group/providers/Microsoft.AzureArcData/sqlServerInstances/$SqlResourceName"
$machine = Invoke-AzRest -Method Get -Url "https://management.azure.com${machineId}?api-version=2024-07-10"
$extension = Invoke-AzRest -Method Get -Url "https://management.azure.com${machineId}/extensions/WindowsAgent.SqlServer?api-version=2024-07-10"
$sql = Invoke-AzRest -Method Get -Url "https://management.azure.com${sqlId}?api-version=2026-01-01"
$databases = Invoke-AzRest -Method Get -Url "https://management.azure.com${sqlId}/databases?api-version=2026-01-01"
$result = [pscustomobject]@{
    ArcResourceId = $machine.id
    ArcStatus = $machine.properties.status
    ExtensionState = $extension.properties.provisioningState
    ExtensionVersion = $extension.properties.typeHandlerVersion
    ExtensionLicense = $extension.properties.settings.LicenseType
    SqlResourceId = $sql.id
    SqlStatus = $sql.properties.status
    SqlVersion = $sql.properties.currentVersion
    SqlEdition = $sql.properties.edition
    LastInventoryUpload = $sql.properties.lastInventoryUploadTime
    Databases = @($databases.value | Select-Object name,@{Name='State';Expression={$_.properties.state}})
    DefenderStatus = $sql.properties.azureDefenderStatus
}
$result
if ($machine.properties.status -ne 'Connected' -or
    $extension.properties.provisioningState -ne 'Succeeded' -or
    $sql.properties.status -ne 'Connected' -or
    $sql.properties.containerResourceId -ine $machineId -or
    @($databases.value).Count -eq 0) {
    throw 'Arc SQL inventory checks did not all pass; inspect actual status and upload time.'
}
