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
$allowed = @('schemaVersion') + $required + @('lobMachineName', 'companionSreRunsheetPath')
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
$values = @{
    RecordedAtUtc = $recorded.UtcDateTime.ToString('o')
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    ArcResourceGroup = $context.resourceGroups.arc
    ArcScope = $arcScope.ToLowerInvariant()
    CompanionSection = 'Arc ends here. Continue in the companion SRE repository only if that part of the demo is prepared.'
    LobAvailability = 'No LOB host is recorded in this context; skip this optional step.'
    LobHostFilter = '| where false // No prepared LOB host in the saved context.'
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
