#Requires -Version 7.4
<#
.SYNOPSIS
    Updates only the operational description of an existing SQL or LOB alert.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('Sql', 'Lob')][string]$Workload,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]$')][string]$MachineName,
    [string]$NamePrefix = 'arc-demo'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-DemoName $NamePrefix
Initialize-DemoContext $SubscriptionId $TenantId
$scope = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix"
$ruleName = if ($Workload -eq 'Sql') { "al-$NamePrefix-sql-lock-timeout" } else { "alert-$NamePrefix-lob-arc-app-fault" }
$id = "$scope/providers/Microsoft.Insights/scheduledQueryRules/$ruleName"
$url = "https://management.azure.com${id}?api-version=2021-08-01"
$before = Invoke-AzRest -Method Get -Url $url
if ($before.id -ne $id -or $before.properties.severity -ne 2 -or
    @($before.properties.scopes).Count -ne 1 -or
    $before.properties.scopes[0] -ne "$scope/providers/Microsoft.OperationalInsights/workspaces/law-$NamePrefix" -or
    @($before.properties.actions.actionGroups).Count -ne 1 -or
    $before.properties.actions.actionGroups[0] -ne "$scope/providers/Microsoft.Insights/actionGroups/ag-$NamePrefix" -or
    $before.properties.criteria.allOf[0].query -notmatch [regex]::Escape($MachineName)) {
    throw 'Existing canonical alert identity, target, severity, workspace or route is unverified; no update.'
}
$description = if ($Workload -eq 'Sql') {
    "A SQL request on $MachineName timed out waiting for a lock (error 1222). Investigate the recorded session and lock-wait evidence."
} else {
    "The application on $MachineName reported a degraded dependency (event 4200). Investigate the application events and dependency health."
}
if ($before.properties.description -eq $description) {
    return [pscustomobject]@{ alertRuleId = $id; changed = $false; description = $description }
}
if (-not $PSCmdlet.ShouldProcess($id, 'Update description only; preserve alert title, predicate, scope, route and settings')) { return }
# Azure can update this read-only API-version metadata even on a description-only PATCH.
$unchanged = $before.properties | Select-Object * -ExcludeProperty description, createdWithApiVersion | ConvertTo-Json -Depth 40 -Compress
$tags = $before.tags | ConvertTo-Json -Depth 10 -Compress
Invoke-AzRest -Method Patch -Url $url -Body @{ properties = @{ description = $description } } | Out-Null
$after = $null
Wait-Until -Message 'canonical alert description readback' -TimeoutSeconds 120 -Condition {
    $script:descriptionReadback = Invoke-AzRest -Method Get -Url $url
    $script:descriptionReadback.properties.description -eq $description
} | Out-Null
$after = $script:descriptionReadback
if ($after.id -ne $id -or
    ($after.properties | Select-Object * -ExcludeProperty description, createdWithApiVersion | ConvertTo-Json -Depth 40 -Compress) -cne $unchanged -or
    ($after.tags | ConvertTo-Json -Depth 10 -Compress) -cne $tags) {
    throw 'Alert readback changed more than description; inspect actual state before any retry.'
}
[pscustomobject]@{
    alertRuleId = $id; changed = $true; description = $description; otherConfigurationUnchanged = $true
    apiVersionMetadataBefore = $before.properties.createdWithApiVersion
    apiVersionMetadataAfter = $after.properties.createdWithApiVersion
}
