<#
.SYNOPSIS
    Generates the private Arc presenter guide from saved nonsecret context.
.DESCRIPTION
    Offline only: does not sign in, query Azure or change the lab. Context and
    output stay together under .local; the tracked runsheet is the only template.

    With -SreGuidePath it also writes .local/full-demo-runsheet.md: one page to run the whole demo from.
    That page is a whole-demo table, the Arc guide as generated, the SRE half taken from the generated SRE
    guide (its own text, byte for byte, under "The night shift (SRE half)", with its steps headed
    "SRE step N" and its close replaced by a pointer) and then the single close, prepared answers and
    reference pages. The SRE guide is read, never changed.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ContextPath = (Join-Path $PSScriptRoot '..\.local\demo-context.json'),
    [switch]$AbsoluteLocalLinks,
    [string]$SreGuidePath
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
function Expand-RunsheetToken {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][hashtable]$Map)
    foreach ($token in @([regex]::Matches($Text, '\{\{([A-Za-z][A-Za-z0-9]*)\}\}'))) {
        $key = $token.Groups[1].Value
        if (-not $Map.ContainsKey($key)) { throw "Unknown presenter template token '$key'." }
        $Text = $Text.Replace($token.Value, [string]$Map[$key])
    }
    if ($Text -match '\{\{|\}\}') { throw 'Unresolved presenter template placeholders remain; output was not written.' }
    $Text
}
function Split-MarkdownLine {
    # Lines keep their own terminators, so text put back together is byte for byte what was read.
    param([Parameter(Mandatory)][string]$Text)
    @([regex]::Split($Text, '(?<=\n)') | Where-Object { $_ -ne '' })
}
function Get-MarkdownHeading {
    # Headings inside fenced code blocks are code, not headings.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line)
    $fenced = $false
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^\s*(```|~~~)') { $fenced = -not $fenced; continue }
        if (-not $fenced -and $Line[$i] -match '^(#{1,6})\s+(.+?)\s*$') {
            [pscustomobject]@{ Index = $i; Level = $Matches[1].Length; Text = $Matches[2] }
        }
    }
}
function ConvertTo-HeadingAnchor {
    param([Parameter(Mandatory)][string]$Heading)
    '#' + (($Heading.ToLowerInvariant() -replace '[^\p{L}\p{N}\s_-]', '') -replace '\s', '-')
}
function ConvertTo-IsoTimestampText {
    # PowerShell 7.4 has no ConvertFrom-Json -DateKind and returns an ISO timestamp as a [datetime]: Utc for Z, Local for an
    # offset. This turns it back into the string it was. With no offset it is Unspecified and comes back unchanged, so the checks reject it.
    param($Value)
    if ($Value -is [datetime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) { return $Value.ToUniversalTime().ToString('o') }
    $Value
}
$contextFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ContextPath)
$directory = Split-Path $contextFile
if ((Split-Path $directory -Leaf) -ne '.local' -or (Split-Path $contextFile -Leaf) -ne 'demo-context.json') {
    throw 'Use .local/demo-context.json; private identifiers must not be written into tracked docs.'
}
if (-not (Test-Path -LiteralPath $contextFile -PathType Leaf)) {
    throw 'Local context is missing. Save your nonsecret deployment inputs and outputs in .local/demo-context.json first.'
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
    'machineIntelligenceWorkbookResourceId', 'complianceWorkbookResourceId',
    'assetInventoryWorkbookResourceId', 'sqlEstateWorkbookResourceId'
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
$context.recordedAtUtc = ConvertTo-IsoTimestampText $context.recordedAtUtc
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
    assetInventoryWorkbookResourceId = 'Microsoft.Insights/workbooks'
    sqlEstateWorkbookResourceId = 'Microsoft.Insights/workbooks'
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
    LobIncidentAvailability = 'No LOB alert rule is recorded in this context; skip this part of the chapter.'
    SqlAvailability = 'No verified real SQL workload is recorded; skip this optional step. A SQL-shaped simulator is not SQL engine proof.'
    SqlHostFilter = '| where false // No verified real SQL workload in this context.'
    SqlHostPhrase = 'the SQL host (the machine whose **Role** is **sql**)'
    SqlIncidentAvailability = 'No SQL incident alert is recorded; skip this part of the chapter.'
    NestedSqlAvailability = 'No nested Arc SQL guest is recorded in this context; skip the nested Arc SQL part of this chapter and say it is not part of this run.'
    DataCollectionRuleAvailability = 'No data collection rule is recorded in this context; explain the idea in words and do not open it.'
    MachineIntelligenceAvailability = 'The Machine Intelligence Center workbook is not recorded in this context; skip its steps in this chapter and say it is not part of this run.'
    ComplianceWorkbookAvailability = 'The compliance workbook is not recorded in this context; skip its steps in this chapter and say it is not part of this run.'
    AssetInventoryAvailability = 'The Asset Inventory workbook is not recorded in this context; skip this optional step.'
    SqlEstateAvailability = 'The SQL Estate workbook is not recorded in this context; skip its steps in this chapter and say it is not part of this run.'
    CapacityWorkbookAvailability = 'The capacity workbook is not recorded as published in this context; skip this chapter and say it is not part of this run. Source templates and preview IDs are not live links.'
    OptimisationWorkbookAvailability = 'The optimisation workbook is not recorded as published in this context; skip this chapter and say it is not part of this run. Source templates and preview IDs are not live links.'
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
    $values.NestedSqlAvailability = 'Prepared nested guest: ' + ($links -join '; ') + '. These links are not proof of current state: judge the chapter by the live **Status** and **Last collected time** on the pages, and skip it if either is not current.'
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
if ($context.Contains('assetInventoryWorkbookResourceId')) {
    $values.AssetInventoryAvailability = "Open [the Asset Inventory workbook]($($values.assetInventoryWorkbookUrl))."
}
if ($context.Contains('sqlEstateWorkbookResourceId')) {
    $values.SqlEstateAvailability = "Open [the SQL Estate workbook, SQL under one view]($($values.sqlEstateWorkbookUrl))."
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
        -not [DateTimeOffset]::TryParse([string](ConvertTo-IsoTimestampText $data.checkedAtUtc), [ref]$checked) -or
        -not [DateTimeOffset]::TryParse([string](ConvertTo-IsoTimestampText $data.lastCommitUtc), [ref]$committed) -or
        $committed -gt $checked -or ($checked - $committed).TotalSeconds -gt 120) {
        throw 'Saved SQL evidence is incomplete, unverified or belongs to a different host; no SQL presentation claim.'
    }
    $proofLink = 'sql-engine-status.json'
        if ($AbsoluteLocalLinks) { $proofLink = ConvertTo-LocalFileLink $proofPath }
        $values.SqlAvailability = "Prepared real SQL host: **$($values.sqlMachineName)**. [Saved engine/query proof]($proofLink): SQL Server $($data.version) Developer, instance ARCDEMO, database ArcDemoOrders, $($data.orderCount) rows; last commit $($committed.UtcDateTime.ToString('o')), checked $($checked.UtcDateTime.ToString('o')). This is dated evidence, not a new guest query."
    $values.SqlHostFilter = '| where tolower(_ResourceId) == "' + $context.sqlMachineResourceId.ToLowerInvariant() + '"'
    $values.SqlHostPhrase = "the SQL host **$($values.sqlMachineName)**"
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
        $values.CompanionSection = "Continue with the [SRE presenter guide]($link). Arc identity and monitoring are already covered; the SRE repo covers the investigation and the Review approval, which you click in the SRE portal."
    }
}
$templateText = Get-Content -LiteralPath (Join-Path $repo 'docs\runsheet.md') -Raw
$template = Expand-RunsheetToken -Text $templateText -Map $values
$output = Join-Path $directory 'presenter-runsheet.md'
$fullOutput = Join-Path $directory 'full-demo-runsheet.md'
$combined = $null
if ($SreGuidePath) {
    if (-not [IO.Path]::IsPathFullyQualified($SreGuidePath)) { throw 'SreGuidePath must be an explicit absolute local path to the generated SRE presenter guide.' }
    if (-not (Test-Path -LiteralPath $SreGuidePath -PathType Leaf)) { throw "The SRE presenter guide was not found at SreGuidePath: $SreGuidePath" }
    $nl = if ($templateText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $sreFile = Split-Path $SreGuidePath -Leaf

    # The SRE guide: its shape is checked first, so a changed guide stops generation instead of being spliced blindly.
    $sreLines = @(Split-MarkdownLine (Get-Content -LiteralPath $SreGuidePath -Raw))
    $sreHeadings = @(Get-MarkdownHeading $sreLines)
    $sreSections = @($sreHeadings | Where-Object Level -eq 2)
    $afternoon = @($sreSections | Where-Object Text -eq 'This afternoon: verified existing investigations')
    $faults = @($sreSections | Where-Object Text -eq 'Live faults')
    $steps = @($sreSections | Where-Object { $_.Text -match '^\d+\. ' })
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($afternoon.Count -ne 1) { $problems.Add("one 'This afternoon: verified existing investigations' heading (found $($afternoon.Count))") }
    if ($faults.Count -ne 1) { $problems.Add("one 'Live faults' heading (found $($faults.Count))") }
    $stepNumbers = @($steps | ForEach-Object { [int](($_.Text -split '\.')[0]) }) -join ','
    if ($stepNumbers -ne '1,2,3,4,5,6,7') { $problems.Add("steps 1 to 7 once each, in order (found '$stepNumbers')") }
    elseif ($steps[6].Text -ne '7. Close') { $problems.Add("step 7 headed 'Close' (found '$($steps[6].Text)')") }
    if (-not $problems.Count -and -not ($afternoon[0].Index -lt $faults[0].Index -and $faults[0].Index -lt $steps[0].Index)) {
        $problems.Add("'This afternoon', 'Live faults' and then the steps, in that order")
    }
    if ($problems.Count) { throw "The SRE guide does not have the expected shape; it needs $($problems -join '; '). The whole-demo run-through was not written." }

    $closeAnchor = ConvertTo-HeadingAnchor 'The close: the Monday answers (2 minutes)'
    $nightHeading = 'The night shift (SRE half)'
    $combinedValues = $values.Clone()
    $combinedValues.CompanionSection = "Continue with [$nightHeading]($(ConvertTo-HeadingAnchor $nightHeading)) below. It is part of this same document, so there is no second guide to open. Arc identity and monitoring are already covered; the SRE half covers the investigation and the Review approval, which you click in the SRE portal."
    $arcText = Expand-RunsheetToken -Text $templateText -Map $combinedValues
    $arcLines = @(Split-MarkdownLine $arcText)
    $arcHeadings = @(Get-MarkdownHeading $arcLines)
    $closeHeading = @($arcHeadings | Where-Object { $_.Level -eq 2 -and $_.Text -eq 'The close: the Monday answers (2 minutes)' })
    $sreHalf = @($arcHeadings | Where-Object { $_.Level -eq 2 -and $_.Text -eq 'Continue with the SRE half' })
    if ($closeHeading.Count -ne 1 -or $sreHalf.Count -ne 1 -or $sreHalf[0].Index -ge $closeHeading[0].Index) {
        throw "The runsheet template needs one 'Continue with the SRE half' heading followed by one 'The close: the Monday answers (2 minutes)' heading to splice the SRE half between them."
    }
    $timedPattern = '^(?<title>Opening: .+?|Chapter \d+\. .+?) \((?<minutes>\d+) minutes?, clock (?<from>\d+:\d+) to (?<to>\d+:\d+)\)$'
    $timed = @($arcHeadings | Where-Object { $_.Level -eq 2 -and $_.Text -match $timedPattern } | ForEach-Object {
            $null = $_.Text -match $timedPattern
            [pscustomobject]@{ Heading = $_.Text; Title = $Matches.title; From = $Matches.from; To = $Matches.to }
        })
    $expectedTitles = @('Opening') + @(1..7 | ForEach-Object { "Chapter $_" })
    $actualTitles = @($timed | ForEach-Object { ($_.Title -split '[:.]')[0] })
    if (($actualTitles -join ',') -ne ($expectedTitles -join ',')) { throw 'The runsheet template needs an Opening and Chapters 1 to 7, each with a clock time in its heading, to build the whole-demo table.' }

    # SRE half: its own lines, with only the numbered step headings renamed and step 7 (the close) pointed at the one close below.
    $sreBody = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(for ($i = 0; $i -lt $afternoon[0].Index; $i++) { $sreLines[$i] })) {
        if ($line.Trim() -and $line -notmatch '^#\s') { $sreBody.Add($line) }
    }
    $stepStarts = @($steps | ForEach-Object { $_.Index })
    for ($i = $afternoon[0].Index; $i -lt $steps[6].Index; $i++) {
        $line = $sreLines[$i]
        if ($i -in $stepStarts) { $line = $line -replace '^## (\d+)\. ', '## SRE step $1. ' }
        $sreBody.Add($line)
    }
    $sreBody.Add("## SRE step 7. Close$nl$nl")
    $sreBody.Add("Close with [The close: the Monday answers]($closeAnchor) below. It is the one close for the whole demo, whether you used live incidents or dated threads.$nl$nl")
    $afterClose = @($sreSections | Where-Object { $_.Index -gt $steps[6].Index } | Select-Object -First 1)
    if ($afterClose.Count) { for ($i = $afterClose[0].Index; $i -lt $sreLines.Count; $i++) { $sreBody.Add($sreLines[$i]) } }

    # The whole-demo table: Arc clock times come from the chapter headings; the SRE half is paced by the alerts.
    $link = { param([string]$Text, [string]$Heading) "[$Text]($(ConvertTo-HeadingAnchor $Heading))" }
    $table = [System.Collections.Generic.List[string]]::new()
    $table.Add('| Clock | Chapter or step | Live-fault point |')
    $table.Add('| --- | --- | --- |')
    foreach ($row in $timed) {
        $fault = ''
        if ($row.Title -match '^Chapter 7\.') {
            $fault = '**Say GO** once the alert rules are shown, ideally on the audience question. Then run **Prepare**: the originals are disabled while the fresh copies exist.'
        }
        $table.Add("| $($row.From) to $($row.To) | $(& $link $row.Title $row.Heading) | $fault |")
    }
    $table.Add("| $($timed[-1].To) | $(& $link 'Continue with the SRE half' 'Continue with the SRE half') | |")
    foreach ($step in $steps[0..5]) {
        $number = [int](($step.Text -split '\.')[0])
        $heading = "SRE step $($step.Text)"
        $clock = if ($number -eq 1) { 'then, paced by the alerts' } else { 'then' }
        $fault = switch ($number) {
            1 { 'Navigation only until GO.' }
            5 { '**Fire SQL**, wait for its alert and thread. Then **fire LOB**. One at a time, cleanup verified between.' }
            6 { '**Fire T09.** Your **Review** click approves only the new investigation''s reset card.' }
            default { '' }
        }
        $table.Add("| $clock | $(& $link $heading $heading) | $fault |")
    }
    $table.Add("| when you say **done** | $(& $link 'Live faults' 'Live faults') | **Restore**: run `-Action Restore` for all three, after the investigations have finished. Originals enabled, copies absent. |")
    $table.Add("| last | $(& $link 'The close: the Monday answers' 'The close: the Monday answers (2 minutes)') | SRE step 7 points here: one close for the whole demo. |")

    $front = @(
        '# Full demo run-through: from servers to the night shift'
        ''
        "This is the one page to run the whole demo from. Follow it from top to bottom: the Arc half, then the night shift (the SRE half), then one close. Links and queries are already filled in. Generation is offline: it did not query Azure or check readiness, and nothing here changes the lab. Combined **$($values.GeneratedAtUtc)** from the Arc guide and ``$sreFile``."
        ''
        '## Whole demo in order'
        ''
    ) + $table + @(
        ''
        "Arc clock times come from the chapter headings. The SRE half has no fixed clock because the alerts set the pace: see $(& $link 'Live faults' 'Live faults'). Read **Live faults** before chapter 7, and keep $(& $link 'This afternoon: verified existing investigations' 'This afternoon: verified existing investigations') open for the dated threads. When asked: $(& $link 'Prepared answers' 'Prepared answers'), $(& $link 'Fallback queries' 'Fallback queries'), $(& $link 'Notes' 'Notes')."
        ''
    )
    $night = @(
        "# $nightHeading"
        ''
        "The text below is the SRE guide's own (``$sreFile``), unchanged: every command, name, number and thread reference is byte for byte as written there. Only its numbered steps are headed **SRE step N**, and its close is a pointer to the one close below. Where it says to complete the Arc section first, or refers to ``.local/presenter-runsheet.md``, you are already in the same document: the Arc part is above."
        ''
    )
    $reference = @(
        '# The close, prepared answers and reference'
        ''
    )
    $arcBefore = -join $arcLines[0..($closeHeading[0].Index - 1)]
    $arcAfter = -join $arcLines[$closeHeading[0].Index..($arcLines.Count - 1)]
    $combined = (($front -join $nl) + $nl + $arcBefore.TrimEnd() + $nl + $nl + ($night -join $nl) + $nl + (-join $sreBody) + ($reference -join $nl) + $nl + $arcAfter)
}
if ($PSCmdlet.ShouldProcess($output, 'Generate private offline Arc presenter guide')) {
    Set-Content -LiteralPath $output -Value $template -Encoding utf8 -NoNewline
    $result = [ordered]@{ Path = $output; ContextRecordedAtUtc = $values.RecordedAtUtc; AzureQueried = $false }
    if ($null -ne $combined -and $PSCmdlet.ShouldProcess($fullOutput, 'Generate private combined Arc and SRE run-through')) {
        Set-Content -LiteralPath $fullOutput -Value $combined -Encoding utf8 -NoNewline
        $result.FullDemoPath = $fullOutput
    }
    [pscustomobject]$result
}
