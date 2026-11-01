#Requires -Version 7.4
<#
.SYNOPSIS
    Previews or deploys one optional workbook against existing Arc inventory/LAW.
.DESCRIPTION
    Preview is the default: only scoped reads and a rendered result, no ARM
    deployment/what-if call. Deploy requires explicit approval/ShouldProcess.
    Never changes guests, collection, retention, prices or lifecycle state.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [ValidateSet('Preview', 'Deploy')][string]$Action = 'Preview',
    [string]$NamePrefix = 'arc-demo',
    [string]$SkinPath = '',
    [string]$TopologyPath = '',
    [ValidateRange(0, 1000000)][decimal]$HypotheticalHourlyRate = 0,
    [ValidateRange(0, 168)][int]$HypotheticalWeeklyHoursOff = 0,
    [string]$HypotheticalMachineResourceId = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\OperationalWorkbooks.psm1') -Force
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
$workspace = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'json') | ConvertFrom-Json
if ($workspace.id -ne $WorkspaceResourceId -or $workspace.location -notmatch '^[a-z0-9]+$') { throw 'Workspace identity/location is unknown.' }
$machines = @(Invoke-DemoAz -Arguments @('connectedmachine', 'list', '-g', $groupName, '-o', 'json') | ConvertFrom-Json)
$options = @{
    Purpose = $Purpose; WorkspaceResourceId = $WorkspaceResourceId; Machines = $machines; Topology = $topology
    HypotheticalHourlyRate = $HypotheticalHourlyRate; HypotheticalWeeklyHoursOff = $HypotheticalWeeklyHoursOff
    HypotheticalMachineResourceId = $HypotheticalMachineResourceId
}
$book = Get-DemoOperationalWorkbook @options
$raw = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $book.ResourceId, '-o', 'json') -AllowNotFound
$existing = if ($raw) { $raw | ConvertFrom-Json } else { $null }
if ($existing -and ($existing.id -ne $book.ResourceId -or $existing.kind -ne 'shared' -or
    $existing.tags.managedBy -ne 'arc-demo-operational-workbooks' -or $existing.tags.purpose -ne $Purpose -or
    $existing.properties.sourceId -ne $WorkspaceResourceId)) {
    throw 'Existing deterministic workbook ownership/source is foreign or ambiguous; no overwrite.'
}
if ($Action -eq 'Preview' -or -not $PSCmdlet.ShouldProcess($book.ResourceId, "Deploy only $Purpose workbook; no collection/lifecycle changes")) {
    return [pscustomobject]@{ status = 'preview'; workbookResourceId = $book.ResourceId; published = $false; workbook = ($book.SerializedData | ConvertFrom-Json -Depth 100) }
}
$path = [IO.Path]::GetTempFileName()
try {
    $values = @{
        location = $workspace.location; workbookName = $book.Name; displayName = $book.DisplayName
        workspaceResourceId = $WorkspaceResourceId.ToLowerInvariant(); serializedData = $book.SerializedData; purpose = $Purpose
    }
    $parameters = @{}
    foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    $deployment = Invoke-DemoAz -Arguments @('deployment', 'group', 'create', '-g', $groupName, '-n', "workbook-$Purpose-$NamePrefix",
        '--template-file', (Join-Path $PSScriptRoot '..\bicep\modules\operational-workbook.bicep'), '--parameters', "@$path", '-o', 'json') | ConvertFrom-Json
    if ($deployment.properties.provisioningState -ne 'Succeeded' -or $deployment.properties.outputs.workbookResourceId.value -ne $book.ResourceId) {
        throw 'Workbook deployment failed/unknown. Inspect this exact deployment before any retry.'
    }
    $actual = Invoke-AzRest -Method GET -Url "https://management.azure.com$($book.ResourceId)?api-version=2023-06-01&canFetchContent=true"
    if ($actual.id -ne $book.ResourceId -or $actual.properties.sourceId -ne $WorkspaceResourceId -or
        $actual.properties.serializedData -cne $book.SerializedData -or $actual.tags.managedBy -ne 'arc-demo-operational-workbooks') {
        throw 'Workbook readback differs from reviewed content; not verified published.'
    }
    [pscustomobject]@{ status = 'published'; workbookResourceId = $book.ResourceId; published = $true }
} finally { [IO.File]::Delete($path) }
