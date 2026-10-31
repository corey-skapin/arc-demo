#Requires -Version 7.4
<#
.SYNOPSIS
    Deploys or inspects only the optional real SQL incident alert.
.DESCRIPTION
    Uses existing workspace/Action Group and retained Windows Arc target.
    No guest execution, DCR change, receiver change, IAM or whole-lab deployment.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('Deploy', 'Status')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,13}[A-Za-z0-9]$')][string]$MachineName,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [Parameter(Mandatory)][string]$ActionGroupId,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$scope = "/subscriptions/$SubscriptionId/resourceGroups/rg-$NamePrefix"
if ($WorkspaceResourceId -notmatch ('^' + [regex]::Escape("$scope/providers/Microsoft.OperationalInsights/workspaces/") + '[A-Za-z0-9._()-]+$') -or
    $ActionGroupId -notmatch ('^' + [regex]::Escape("$scope/providers/Microsoft.Insights/actionGroups/") + '[A-Za-z0-9._()-]+$')) {
    throw 'Use exact existing workspace and Action Group IDs in this confirmed subscription/Arc group.'
}
Initialize-DemoContext $SubscriptionId $TenantId
$inventory = Get-DemoInventory $NamePrefix
Assert-DemoSkinInventory $skin $inventory
$targets = @($inventory.Machines | Where-Object Name -eq $MachineName)
if ($targets.Count -ne 1 -or $targets[0].Native -or $targets[0].OsType -ne 'Windows' -or
    -not $targets[0].Actual -or $targets[0].Actual.storageProfile.osDisk.osType -ne 'Windows') {
    throw 'Alert target must be one retained Windows Arc-backed VM; no unknown/native target.'
}
$workspace = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'json') | ConvertFrom-Json
$group = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $ActionGroupId, '-o', 'json') | ConvertFrom-Json
$receivers = @($group.properties.emailReceivers) + @($group.properties.webhookReceivers) + @($group.properties.azureFunctionReceivers)
if ($workspace.id -ne $WorkspaceResourceId -or $workspace.location -notmatch '^[a-z0-9]+$' -or $group.id -ne $ActionGroupId -or
    $group.properties.enabled -ne $true -or -not @($receivers | Where-Object useCommonAlertSchema -eq $true).Count) {
    throw 'Workspace/Action Group identity, location or enabled common-schema receiver is unverified; no receiver repair.'
}
$alertId = "$scope/providers/Microsoft.Insights/scheduledQueryRules/al-$NamePrefix-sql-lock-timeout"
$raw = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $alertId, '-o', 'json') -AllowNotFound
$existing = if ($raw) { $raw | ConvertFrom-Json } else { $null }
if ($existing -and ($existing.id -ne $alertId -or $existing.tags.managedBy -ne 'arc-demo-sql-incident' -or
    @($existing.properties.scopes).Count -ne 1 -or $existing.properties.scopes[0] -ne $WorkspaceResourceId -or
    @($existing.properties.actions.actionGroups).Count -ne 1 -or $existing.properties.actions.actionGroups[0] -ne $ActionGroupId -or
    $existing.properties.criteria.allOf[0].query -notmatch [regex]::Escape($targets[0].ArcId.ToLowerInvariant()))) {
    throw 'Existing alert ownership/target/route is foreign or ambiguous; no overwrite.'
}
if ($Action -eq 'Status') {
    if (-not $existing) { throw 'SQL incident alert is absent; not ready.' }
    return $existing
}
if (-not $PSCmdlet.ShouldProcess($alertId, 'Deploy only Sev2 SQL lock-timeout log alert using existing Action Group')) { return }
$path = [IO.Path]::GetTempFileName()
try {
    $values = @{
        location = $workspace.location; namePrefix = $NamePrefix; workspaceResourceId = $WorkspaceResourceId
        machineResourceId = $targets[0].ArcId; actionGroupId = $ActionGroupId
    }
    $parameters = @{}
    foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    $deployment = Invoke-DemoAz -Arguments @('deployment', 'group', 'create', '-g', $inventory.ArcRg, '-n', "sql-incident-$NamePrefix",
        '--template-file', (Join-Path $PSScriptRoot '..\bicep\modules\sql-incident-alert.bicep'), '--parameters', "@$path", '-o', 'json') | ConvertFrom-Json
    if ($deployment.properties.provisioningState -ne 'Succeeded' -or $deployment.properties.outputs.alertRuleId.value -ne $alertId) {
        throw 'SQL alert deployment failed/unknown; inspect actual deployment before retrying.'
    }
    [pscustomobject]@{ alertRuleId = $alertId; status = 'deployed'; severity = 2; titleKeyword = 'Arc SQL lock timeout' }
} finally { [IO.File]::Delete($path) }
