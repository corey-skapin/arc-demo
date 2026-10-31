<#
.SYNOPSIS
    Generates the private Arc presenter guide from saved nonsecret context.
.DESCRIPTION
    Offline only: does not sign in, query Azure or change the lab. Context and
    output stay together under .local; the tracked runsheet is the only template.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot '..\.local\demo-context.json')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
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
    'capacityWorkbookResourceId', 'optimisationWorkbookResourceId'
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
$values = @{
    RecordedAtUtc = $recorded.UtcDateTime.ToString('o')
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    ArcResourceGroup = $context.resourceGroups.arc
    ArcScope = $arcScope.ToLowerInvariant()
    CompanionSection = 'Arc ends here. Continue in the companion SRE repository only if that part of the demo is prepared.'
    LobAvailability = 'No LOB host is recorded in this context; skip this optional step.'
    LobHostFilter = '| where false // No prepared LOB host in the saved context.'
    SqlAvailability = 'No verified real SQL workload is recorded; skip this optional step. A SQL-shaped simulator is not SQL engine proof.'
    SqlHostFilter = '| where false // No verified real SQL workload in this context.'
    SqlIncidentAvailability = 'No SQL incident alert is recorded; skip the incident beat.'
    OperationalWorkbookSection = 'Optional capacity/optimisation workbooks are not recorded as published; skip this beat. Source templates and preview IDs are not live links.'
}
$portal = "https://portal.azure.com/#@$($context.tenantId)/resource"
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
$operationalLinks = @()
if ($context.Contains('capacityWorkbookResourceId')) {
    $operationalLinks += "[Capacity and headroom]($($values.capacityWorkbookUrl)): compare CPU mean/P95/maximum, memory pressure and per-volume free-space trend only where there are actual samples."
}
if ($context.Contains('optimisationWorkbookResourceId')) {
    $operationalLinks += "[Optimisation opportunities]($($values.optimisationWorkbookUrl)): start with ownership/evidence gaps; explain a review candidate rather than promising a resize or savings."
}
if ($operationalLinks.Count) {
    $values.OperationalWorkbookSection = ($operationalLinks -join "`n`n") + "`n`nCheck freshness, coverage and history warnings first. Missing data is not zero; parked gaps are not idle headroom. Parent/guest rows are separate observations, never additive hardware capacity. Hypothetical operator inputs are not billed or realised savings. These links record publication only, not current telemetry health."
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
    $values.SqlAvailability = "Prepared real SQL host: **$($values.sqlMachineName)**. [Saved engine/query proof](sql-engine-status.json): SQL Server $($data.version) Developer, instance ARCDEMO, database ArcDemoOrders, $($data.orderCount) rows; last commit $($committed.UtcDateTime.ToString('o')), checked $($checked.UtcDateTime.ToString('o')). This is dated evidence, not a new guest query."
    $values.SqlHostFilter = '| where tolower(_ResourceId) == "' + $context.sqlMachineResourceId.ToLowerInvariant() + '"'
}
if ($context.Contains('sqlIncidentAlertResourceId')) {
    $values.SqlIncidentAvailability = "Recorded [SQL incident alert]($($values.sqlIncidentAlertUrl)), **$($values.sqlIncidentAlertName)**. This link is not proof of an alert firing or an SRE investigation; verify the live run below."
}
if ($context.Contains('lobMachineName')) {
    if ($context.lobMachineName -isnot [string] -or $context.lobMachineName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'lobMachineName must be the explicitly prepared host name, not a query or a guessed default.'
    }
    $values.LobAvailability = "Prepared LOB host: **$($context.lobMachineName)**. Use fresh rows, not old rehearsal faults."
    $values.LobHostFilter = '| where Computer =~ "' + $context.lobMachineName + '"'
}
if ($context.Contains('companionSreRunsheetPath')) {
    $companion = [string]$context.companionSreRunsheetPath
    if (-not [IO.Path]::IsPathFullyQualified($companion)) { throw 'companionSreRunsheetPath must be an explicit absolute local path.' }
    if (Test-Path -LiteralPath $companion -PathType Leaf) {
        $relative = [IO.Path]::GetRelativePath($directory, $companion)
        if ([IO.Path]::IsPathRooted($relative)) { throw 'Companion guide must be on the same drive to create a relative Markdown link.' }
        $link = (($relative -split '[\\/]') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
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
