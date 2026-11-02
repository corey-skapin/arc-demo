<#
.SYNOPSIS
    Generates the private Arc presenter guide from saved nonsecret context.
.DESCRIPTION
    Offline only: does not sign in, query Azure or change the lab. Context and
    output stay together under .local; the tracked runsheet is the only template.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot '..\.local\demo-context.json'),
    [switch]$AbsoluteLocalLinks
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
function ConvertTo-LocalFileLink {
    # Pure string work so Windows and Linux paths both give file:/// links; a [uri] cast would treat a Unix path as relative.
    param([Parameter(Mandatory)][string]$LocalPath)
    $segments = @(($LocalPath -replace '\\', '/') -split '/' | ForEach-Object {
            if ($_ -match '^[A-Za-z]:$') { $_ } else { [uri]::EscapeDataString($_) }
        })
    $joined = $segments -join '/'
    if ($joined.StartsWith('/')) { "file://$joined" } else { "file:///$joined" }
}
$contextFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ContextPath)
$directory = Split-Path $contextFile
if ((Split-Path $directory -Leaf) -ne '.local' -or (Split-Path $contextFile -Leaf) -ne 'demo-context.json') {
    throw 'Use .local/demo-context.json; private identifiers must not be written into tracked docs.'
}
if (-not (Test-Path -LiteralPath $contextFile -PathType Leaf)) {
    throw 'Local context is missing. Ask the preparing operator/agent to save approved deployment inputs and outputs in .local/demo-context.json.'
}
$jsonOptions = @{ AsHashtable = $true }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
$context = Get-Content -LiteralPath $contextFile -Raw | ConvertFrom-Json @jsonOptions
if ($context -isnot [System.Collections.IDictionary] -or $context.schemaVersion -isnot [long] -or $context.schemaVersion -ne 1) {
    throw 'Context must be a JSON object with numeric schemaVersion 1.'
}
$required = @(
    'tenantId', 'subscriptionId', 'recordedAtUtc', 'resourceGroups',
    'workspaceResourceId', 'workbookResourceId', 'windowsMachineResourceId',
    'linuxMachineResourceId', 'heartbeatAlertResourceId', 'actionGroupResourceId'
)
$allowed = @('schemaVersion') + $required + @(
    'lobMachineName', 'companionSreRunsheetPath', 'sqlMachineResourceId', 'sqlIncidentAlertResourceId',
    'capacityWorkbookResourceId', 'optimisationWorkbookResourceId',
    'nestedSqlMachineResourceId', 'nestedSqlInstanceResourceId', 'nestedSqlParentMachineResourceId',
    'lobIncidentAlertResourceId', 'dataCollectionRuleResourceId',
    'machineIntelligenceWorkbookResourceId', 'complianceWorkbookResourceId'
)
foreach ($entry in $context.GetEnumerator()) {
    if ($entry.Key -notin $allowed) { throw "Unsupported context field '$($entry.Key)'. Store only the documented nonsecret presenter fields." }
}
foreach ($field in $required) {
    if (-not $context.Contains($field) -or $null -eq $context[$field] -or "$($context[$field])".Trim() -eq '') {
        throw "Required presenter context field '$field' is missing."
    }
}
foreach ($field in @('tenantId', 'subscriptionId')) {
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$context[$field], [ref]$id) -or $id -eq [guid]::Empty) {
        throw "Context '$field' must be an explicit nonempty GUID."
    }
    $context[$field] = $id.ToString()
}
$recorded = [DateTimeOffset]::MinValue
if ($context.recordedAtUtc -isnot [string] -or
    $context.recordedAtUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -or
    -not [DateTimeOffset]::TryParse($context.recordedAtUtc, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$recorded)) {
    throw 'recordedAtUtc must be a dated ISO timestamp with an explicit UTC offset; generation does not verify readiness.'
}
if ($context.resourceGroups -isnot [System.Collections.IDictionary]) { throw 'resourceGroups must contain arc and infra names.' }
foreach ($entry in $context.resourceGroups.GetEnumerator()) {
    if ($entry.Key -notin @('arc', 'infra', 'sre')) { throw "Unsupported resourceGroups field '$($entry.Key)'." }
}
foreach ($group in @('arc', 'infra')) {
    if ($context.resourceGroups[$group] -isnot [string] -or $context.resourceGroups[$group] -notmatch '^[A-Za-z0-9][A-Za-z0-9._()-]{0,89}$') {
        throw "resourceGroups.$group must be an explicit resource-group name."
    }
}
$arcScope = "/subscriptions/$($context.subscriptionId)/resourceGroups/$($context.resourceGroups.arc)"
$types = [ordered]@{
    workspaceResourceId = 'Microsoft.OperationalInsights/workspaces'
    workbookResourceId = 'Microsoft.Insights/workbooks'
    windowsMachineResourceId = 'Microsoft.HybridCompute/machines'
    linuxMachineResourceId = 'Microsoft.HybridCompute/machines'
    heartbeatAlertResourceId = 'Microsoft.Insights/scheduledQueryRules'
    actionGroupResourceId = 'Microsoft.Insights/actionGroups'
}
if ($context.Contains('sqlMachineResourceId')) { $types['sqlMachineResourceId'] = 'Microsoft.HybridCompute/machines' }
if ($context.Contains('sqlIncidentAlertResourceId')) {
    if (-not $context.Contains('sqlMachineResourceId')) { throw 'SQL incident context requires the prepared real SQL host and query proof first.' }
    $types['sqlIncidentAlertResourceId'] = 'Microsoft.Insights/scheduledQueryRules'
}
foreach ($field in @('capacityWorkbookResourceId', 'optimisationWorkbookResourceId')) {
    if ($context.Contains($field)) { $types[$field] = 'Microsoft.Insights/workbooks' }
}
foreach ($field in @('nestedSqlInstanceResourceId', 'nestedSqlParentMachineResourceId')) {
    if ($context.Contains($field) -and -not $context.Contains('nestedSqlMachineResourceId')) {
        throw "Context '$field' requires the nested guest Arc machine (nestedSqlMachineResourceId) first."
    }
}
if ($context.Contains('lobIncidentAlertResourceId') -and -not $context.Contains('lobMachineName')) {
    throw 'LOB incident alert context requires the prepared lobMachineName first.'
}
$optionalTypes = [ordered]@{
    nestedSqlMachineResourceId = 'Microsoft.HybridCompute/machines'
    nestedSqlInstanceResourceId = 'Microsoft.AzureArcData/SqlServerInstances'
    nestedSqlParentMachineResourceId = 'Microsoft.HybridCompute/machines'
    lobIncidentAlertResourceId = 'Microsoft.Insights/scheduledQueryRules'
    dataCollectionRuleResourceId = 'Microsoft.Insights/dataCollectionRules'
    machineIntelligenceWorkbookResourceId = 'Microsoft.Insights/workbooks'
    complianceWorkbookResourceId = 'Microsoft.Insights/workbooks'
}
foreach ($entry in $optionalTypes.GetEnumerator()) {
    if ($context.Contains($entry.Key)) { $types[$entry.Key] = $entry.Value }
}
$values = @{
    RecordedAtUtc = $recorded.UtcDateTime.ToString('o')
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    ArcResourceGroup = $context.resourceGroups.arc
    ArcScope = $arcScope.ToLowerInvariant()
    CompanionSection = 'Arc ends here. Continue in the companion SRE repository only if that part of the demo is prepared.'
    LobAvailability = 'No LOB host is recorded in this context; skip this optional step.'
    LobHostFilter = '| where false // No prepared LOB host in the saved context.'
    LobIncidentAvailability = 'No LOB alert rule is recorded in this context; skip this part of the scene.'
    SqlAvailability = 'No verified real SQL workload is recorded; skip this optional step. A SQL-shaped simulator is not SQL engine proof.'
    SqlHostFilter = '| where false // No verified real SQL workload in this context.'
    SqlIncidentAvailability = 'No SQL incident alert is recorded; skip this part of the scene.'
    NestedSqlAvailability = 'No nested Arc SQL guest is recorded in this context; skip scene 3b and say it is not part of this run.'
    DataCollectionRuleAvailability = 'No data collection rule is recorded in this context; explain the idea in words and do not open it.'
    MachineIntelligenceAvailability = 'The Machine Intelligence Center workbook is not recorded in this context; skip this optional step.'
    ComplianceWorkbookAvailability = 'The compliance workbook is not recorded in this context; skip this optional step.'
    CapacityWorkbookAvailability = 'The capacity workbook is not recorded as published in this context; skip this scene and say it is not part of this run. Source templates and preview IDs are not live links.'
    OptimisationWorkbookAvailability = 'The optimisation workbook is not recorded as published in this context; skip this scene and say it is not part of this run. Source templates and preview IDs are not live links.'
}
$portal = "https://portal.azure.com/#@$($context.tenantId)/resource"
$values.ResourceGroupUrl = $portal + ((($arcScope -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/') + '/overview'
foreach ($entry in $types.GetEnumerator()) {
    $resource = [string]$context[$entry.Key]
    $pattern = '^' + [regex]::Escape("$arcScope/providers/$($entry.Value)/") + '[A-Za-z0-9._()-]+$'
    if ($resource -notmatch $pattern) { throw "$($entry.Key) must identify the expected resource type in this exact subscription and Arc resource group." }
    $name = ($resource -split '/')[-1]
    $token = $entry.Key -replace 'ResourceId$', ''
    $encodedResource = (($resource -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $values["${token}Url"] = $portal + $encodedResource
    $values["${token}Name"] = $name
}
if ($context.Contains('capacityWorkbookResourceId')) {
    $values.CapacityWorkbookAvailability = "Open [Capacity and headroom]($($values.capacityWorkbookUrl)). This link records publication only, not current telemetry health."
}
if ($context.Contains('optimisationWorkbookResourceId')) {
    $values.OptimisationWorkbookAvailability = "Open [Optimisation opportunities]($($values.optimisationWorkbookUrl)). This link records publication only, not current telemetry health."
}
if ($context.Contains('nestedSqlMachineResourceId')) {
    $links = @("the nested guest's Arc machine [$($values.nestedSqlMachineName)]($($values.nestedSqlMachineUrl))")
    if ($context.Contains('nestedSqlInstanceResourceId')) {
        $links += "its SQL Server instance [$($values.nestedSqlInstanceName)]($($values.nestedSqlInstanceUrl))"
    }
    if ($context.Contains('nestedSqlParentMachineResourceId')) {
        $links += "the backing parent host [$($values.nestedSqlParentMachineName)]($($values.nestedSqlParentMachineUrl))"
    }
    $values.NestedSqlAvailability = 'Prepared nested guest: ' + ($links -join '; ') + '. These links are not proof of current state: judge the scene by the live **Status** and **Last collected time** on the pages, and skip it if either is not current.'
}
if ($context.Contains('dataCollectionRuleResourceId')) {
    $values.DataCollectionRuleAvailability = "Open [the data collection rule]($($values.dataCollectionRuleUrl)), **$($values.dataCollectionRuleName)**, read-only."
}
if ($context.Contains('machineIntelligenceWorkbookResourceId')) {
    $values.MachineIntelligenceAvailability = "Open [the Machine Intelligence Center workbook]($($values.machineIntelligenceWorkbookUrl))."
}
if ($context.Contains('complianceWorkbookResourceId')) {
    $values.ComplianceWorkbookAvailability = "Open [the Compliance, Security and Governance workbook]($($values.complianceWorkbookUrl))."
}
if ($context.Contains('lobIncidentAlertResourceId')) {
    $values.LobIncidentAvailability = "Recorded [LOB alert rule]($($values.lobIncidentAlertUrl)), **$($values.lobIncidentAlertName)**. This link is not proof of an alert firing or an SRE investigation."
}
if ($context.Contains('sqlMachineResourceId')) {
    $proofPath = Join-Path $directory 'sql-engine-status.json'
    if (-not (Test-Path -LiteralPath $proofPath -PathType Leaf)) { throw 'SQL presenter context requires adjacent sql-engine-status.json from a successful real SQL Status query.' }
    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json @jsonOptions
    $data = $proof.evidence
    $checked = [DateTimeOffset]::MinValue
    $committed = [DateTimeOffset]::MinValue
    if ($proof.schemaVersion -ne 1 -or $proof.workload -ne 'arc-sql-engine' -or $proof.action -ne 'Status' -or
        $proof.resourceId -ne $context.sqlMachineResourceId -or $data.status -ne 'pass' -or
        $data.instance -ne 'ARCDEMO' -or $data.database -ne 'ArcDemoOrders' -or
        $data.edition -notmatch '^Developer Edition(?: \(64-bit\))?$' -or $data.version -notmatch '^16\.\d+\.\d+\.\d+$' -or
        $data.orderCount -isnot [long] -or $data.orderCount -lt 1 -or $data.orderCount -gt 1000 -or
        -not [DateTimeOffset]::TryParse([string]$data.checkedAtUtc, [ref]$checked) -or
        -not [DateTimeOffset]::TryParse([string]$data.lastCommitUtc, [ref]$committed) -or
        $committed -gt $checked -or ($checked - $committed).TotalSeconds -gt 120) {
        throw 'Saved SQL evidence is incomplete, unverified or belongs to a different host; no SQL presentation claim.'
    }
    $proofLink = 'sql-engine-status.json'
        if ($AbsoluteLocalLinks) { $proofLink = ConvertTo-LocalFileLink $proofPath }
        $values.SqlAvailability = "Prepared real SQL host: **$($values.sqlMachineName)**. [Saved engine/query proof]($proofLink): SQL Server $($data.version) Developer, instance ARCDEMO, database ArcDemoOrders, $($data.orderCount) rows; last commit $($committed.UtcDateTime.ToString('o')), checked $($checked.UtcDateTime.ToString('o')). This is dated evidence, not a new guest query."
    $values.SqlHostFilter = '| where tolower(_ResourceId) == "' + $context.sqlMachineResourceId.ToLowerInvariant() + '"'
}
if ($context.Contains('sqlIncidentAlertResourceId')) {
    $values.SqlIncidentAvailability = "Recorded [SQL incident alert]($($values.sqlIncidentAlertUrl)), **$($values.sqlIncidentAlertName)**. This link is not proof of an alert firing or an SRE investigation; investigations are read in the SRE guide, live or dated."
}
if ($context.Contains('lobMachineName')) {
    if ($context.lobMachineName -isnot [string] -or $context.lobMachineName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'lobMachineName must be the explicitly prepared host name, not a query or a guessed default.'
    }
    $values.LobAvailability = "Prepared LOB host: **$($context.lobMachineName)**. Use fresh rows, not an earlier incident's rows."
    $values.LobHostFilter = '| where Computer =~ "' + $context.lobMachineName + '"'
}
if ($context.Contains('companionSreRunsheetPath')) {
    $companion = [string]$context.companionSreRunsheetPath
    if (-not [IO.Path]::IsPathFullyQualified($companion)) { throw 'companionSreRunsheetPath must be an explicit absolute local path.' }
    if (Test-Path -LiteralPath $companion -PathType Leaf) {
        if ($AbsoluteLocalLinks) {
            $link = ConvertTo-LocalFileLink $companion
        } else {
            $relative = [IO.Path]::GetRelativePath($directory, $companion)
            if ([IO.Path]::IsPathRooted($relative)) { throw 'Companion guide must be on the same drive to create a relative Markdown link.' }
            $link = (($relative -split '[\\/]') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        }
        $values.CompanionSection = "Continue with the [SRE presenter guide]($link). Arc identity and monitoring are already covered; the SRE repo owns investigation and human Review approval."
    }
}
$template = Get-Content -LiteralPath (Join-Path $repo 'docs\runsheet.md') -Raw
$tokens = @([regex]::Matches($template, '\{\{([A-Za-z][A-Za-z0-9]*)\}\}'))
foreach ($token in $tokens) {
    $key = $token.Groups[1].Value
    if (-not $values.ContainsKey($key)) { throw "Unknown presenter template token '$key'." }
    $template = $template.Replace($token.Value, [string]$values[$key])
}
if ($template -match '\{\{|\}\}') { throw 'Unresolved presenter template placeholders remain; output was not written.' }
$output = Join-Path $directory 'presenter-runsheet.md'
if ($PSCmdlet.ShouldProcess($output, 'Generate private offline Arc presenter guide')) {
    Set-Content -LiteralPath $output -Value $template -Encoding utf8 -NoNewline
    [pscustomobject]@{ Path = $output; ContextRecordedAtUtc = $values.RecordedAtUtc; AzureQueried = $false }
}
