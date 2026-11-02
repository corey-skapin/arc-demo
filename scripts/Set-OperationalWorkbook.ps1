#Requires -Version 7.4
<#
.SYNOPSIS
    Previews, deploys or (drafts only) removes one optional operational workbook against existing Arc inventory/LAW.
.DESCRIPTION
    Preview is the default: only scoped reads and a rendered result, no ARM deployment/what-if call.
    Deploy requires explicit approval/ShouldProcess. Never changes guests, collection, retention, prices or lifecycle state.

    -Draft renders and deploys a separate "(draft)" copy with its own deterministic ID, so the published workbook stays
    intact while it is reviewed in the portal. Promotion is the same command without -Draft (it replaces the published
    workbook in place); -Action Remove -Draft then deletes only the draft this script owns.

    The nested SQL guest is read from the skin's nestedSqlGuest block (parent and Arc machine names) and declared as a
    parent/guest pair in the roster. A guest that is not an Arc machine yet is skipped with a warning; a disconnected guest
    is still listed. Guests are never counted as independent capacity. An optional -TopologyPath file may declare more.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [ValidateSet('Preview', 'Deploy', 'Remove')][string]$Action = 'Preview',
    [switch]$Draft,
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$TopologyPath = '',
    [ValidateRange(-12, 14)][decimal]$DisplayUtcOffsetHours = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\OperationalWorkbooks.psm1') -Force
if ($Action -eq 'Remove' -and -not $Draft) {
    throw 'Only a draft workbook can be removed here. The published workbook goes with the lab group on approved normal removal.'
}
$skin = Get-DemoSkin -Path $SkinPath -RepoRoot (Split-Path $PSScriptRoot)
if (-not $PSBoundParameters.ContainsKey('NamePrefix')) { $NamePrefix = Get-DemoSkinValue $skin 'azure.namePrefix' $NamePrefix }
Assert-DemoName $NamePrefix
$groupName = "rg-$NamePrefix"
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$groupName"
if ($WorkspaceResourceId -notmatch ('^' + [regex]::Escape("$scope/providers/Microsoft.OperationalInsights/workspaces/") + '[A-Za-z0-9._()-]+$')) {
    throw 'Select an exact existing workspace ID in this confirmed subscription/Arc group.'
}
$topology = @()
if ($TopologyPath) {
    $saved = Get-Content -LiteralPath $TopologyPath -Raw | ConvertFrom-Json -Depth 10
    if ($saved.schemaVersion -isnot [long] -or $saved.schemaVersion -ne 1 -or $saved.machines -isnot [array] -or
        @($saved.PSObject.Properties.Name | Where-Object { $_ -notin @('schemaVersion', 'machines') }).Count) {
        throw 'Topology must contain schemaVersion 1 and machines only.'
    }
    $topology = @($saved.machines)
}
Initialize-DemoContext $SubscriptionId $TenantId
$identity = Get-DemoOperationalWorkbookIdentity -Purpose $Purpose -WorkspaceResourceId $WorkspaceResourceId -Draft:$Draft
$book = $null
$workspace = $null
if ($Action -ne 'Remove') {
    # Removal needs only the deterministic identity, so a draft can still be cleaned up after the Arc roster is gone or unreadable.
    $workspace = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'json') | ConvertFrom-Json
    if ($workspace.id -ne $WorkspaceResourceId -or $workspace.location -notmatch '^[a-z0-9]+$') { throw 'Workspace identity/location is unknown.' }
    $machines = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $groupName, '-o', 'json') | ConvertFrom-Json)
    $nested = ConvertTo-DemoNestedTopology -NestedGuest (Get-DemoNestedSqlGuestConfig $skin) -Machines $machines -WorkspaceResourceId $WorkspaceResourceId
    foreach ($declared in $nested) {
        $explicit = @($topology | Where-Object { ([string]$_.resourceId).ToLowerInvariant() -eq $declared.resourceId })
        if (-not $explicit.Count) { $topology += $declared; continue }
        $parent = if ($explicit[0].PSObject.Properties.Name -contains 'parentResourceId') { ([string]$explicit[0].parentResourceId).ToLowerInvariant() } else { '' }
        if ($explicit[0].layer -ne $declared.layer -or $parent -ne [string]$declared.parentResourceId) {
            throw 'The topology file conflicts with the skin nestedSqlGuest declaration; fix one of them.'
        }
    }
    $book = Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $WorkspaceResourceId -Machines $machines -Topology $topology `
        -Draft:$Draft -DisplayUtcOffsetHours $DisplayUtcOffsetHours -TenantId $TenantId.ToString()
}
$raw = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $identity.ResourceId, '-o', 'json') -AllowNotFound
$existing = if ($raw) { $raw | ConvertFrom-Json } else { $null }
if ($existing -and ($existing.id -ne $identity.ResourceId -or $existing.kind -ne 'shared' -or
    $existing.tags.managedBy -ne 'arc-demo-operational-workbooks' -or $existing.tags.purpose -ne $Purpose -or
    $existing.properties.sourceId -ne $WorkspaceResourceId)) {
    throw 'Existing deterministic workbook ownership/source is foreign or ambiguous; no overwrite.'
}
if ($existing -and [bool]$Draft -ne ($existing.tags.PSObject.Properties.Name -contains 'lifecycle' -and $existing.tags.lifecycle -eq 'draft')) {
    throw 'Existing deterministic workbook draft marking does not match this request; no overwrite.'
}
if ($Action -eq 'Remove') {
    if (-not $existing) { return [pscustomobject]@{ status = 'absent'; workbookResourceId = $identity.ResourceId; removed = $false } }
    if (-not $PSCmdlet.ShouldProcess($identity.ResourceId, "Delete only the $Purpose draft workbook")) {
        return [pscustomobject]@{ status = 'preview'; workbookResourceId = $identity.ResourceId; removed = $false }
    }
    Invoke-DemoAz -Arguments @('resource', 'delete', '--ids', $identity.ResourceId) | Out-Null
    if (Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $identity.ResourceId, '-o', 'json') -AllowNotFound) {
        throw 'Draft workbook is still present after deletion; inspect it before any retry.'
    }
    return [pscustomobject]@{ status = 'removed'; workbookResourceId = $identity.ResourceId; removed = $true }
}
$target = if ($Draft) { "$Purpose draft workbook" } else { "$Purpose workbook" }
if ($Action -eq 'Preview' -or -not $PSCmdlet.ShouldProcess($book.ResourceId, "Deploy only the $target; no collection/lifecycle changes")) {
    return [pscustomobject]@{ status = 'preview'; workbookResourceId = $book.ResourceId; published = $false; draft = [bool]$Draft; workbook = ($book.SerializedData | ConvertFrom-Json -Depth 100) }
}
$path = [IO.Path]::GetTempFileName()
try {
    $values = @{
        location = $workspace.location; workbookName = $book.Name; displayName = $book.DisplayName
        workspaceResourceId = $WorkspaceResourceId.ToLowerInvariant(); serializedData = $book.SerializedData; purpose = $Purpose
        draft = [bool]$Draft
    }
    $parameters = @{}
    foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    $deploymentName = "workbook-$Purpose-$NamePrefix" + $(if ($Draft) { '-draft' } else { '' })
    $deployment = Invoke-DemoAz -Arguments @('deployment', 'group', 'create', '-g', $groupName, '-n', $deploymentName,
        '--template-file', (Join-Path $PSScriptRoot '..\bicep\modules\operational-workbook.bicep'), '--parameters', "@$path", '-o', 'json') | ConvertFrom-Json
    if ($deployment.properties.provisioningState -ne 'Succeeded' -or $deployment.properties.outputs.workbookResourceId.value -ne $book.ResourceId) {
        throw 'Workbook deployment failed/unknown. Inspect this exact deployment before any retry.'
    }
    $actual = Invoke-AzRest -Method GET -Url "https://management.azure.com$($book.ResourceId)?api-version=2023-06-01&canFetchContent=true"
    if ($actual.id -ne $book.ResourceId -or $actual.properties.sourceId -ne $WorkspaceResourceId -or
        $actual.properties.serializedData -cne $book.SerializedData -or $actual.tags.managedBy -ne 'arc-demo-operational-workbooks') {
        throw 'Workbook readback differs from reviewed content; not verified published.'
    }
    [pscustomobject]@{ status = $(if ($Draft) { 'draft-published' } else { 'published' }); workbookResourceId = $book.ResourceId; published = (-not $Draft); draft = [bool]$Draft }
} finally { [IO.File]::Delete($path) }
