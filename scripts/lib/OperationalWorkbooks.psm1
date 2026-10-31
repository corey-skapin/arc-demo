#Requires -Version 7.4
Set-StrictMode -Version Latest

function Get-DemoOperationalScenario {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 1000000)][decimal]$HourlyRate = 0,
        [ValidateRange(0, 168)][int]$WeeklyHoursOff = 0
    )
    [pscustomobject]@{
        HourlyRate = $HourlyRate
        WeeklyHoursOff = $WeeklyHoursOff
        Weeks = 4
        HypotheticalAvoidedCompute = $HourlyRate * $WeeklyHoursOff * 4
    }
}

function Get-DemoOperationalWorkbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][object[]]$Machines,
        [object[]]$Topology = @(),
        [ValidateRange(0, 1000000)][decimal]$HypotheticalHourlyRate = 0,
        [ValidateRange(0, 168)][int]$HypotheticalWeeklyHoursOff = 0,
        [string]$HypotheticalMachineResourceId = ''
    )
    $workspacePattern = '^(/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._()-]+)/providers/Microsoft.OperationalInsights/workspaces/[A-Za-z0-9._()-]+$'
    if ($WorkspaceResourceId -notmatch $workspacePattern) { throw 'Expected an exact workspace resource ID.' }
    $scope = $Matches[1]
    $machinePattern = '^' + [regex]::Escape("$scope/providers/Microsoft.HybridCompute/machines/") + '[A-Za-z0-9._()-]+$'
    if ($Machines.Count -lt 1 -or $Machines.Count -gt 100) { throw 'Select 1-100 exact Arc resources, not an unbounded estate.' }
    $roster = @{}
    foreach ($machine in $Machines) {
        $id = [string]$machine.id
        if ($id -notmatch $machinePattern -or $roster.ContainsKey($id)) { throw 'Foreign, malformed or duplicate Arc identity in workbook roster.' }
        $roster[$id] = [ordered]@{
            resourceId = $id.ToLowerInvariant()
            machine = ($id -split '/')[-1]
            layer = 'unclassified'
            parentResourceId = ''
        }
    }
    $seen = @{}
    foreach ($entry in $Topology) {
        $keys = @($entry.PSObject.Properties.Name)
        if ($entry -is [System.Collections.IDictionary]) { $keys = @($entry.Keys) }
        if (@($keys | Where-Object { $_ -notin @('resourceId', 'layer', 'parentResourceId') }).Count -or
            'resourceId' -notin $keys -or 'layer' -notin $keys) { throw 'Topology requires resourceId/layer and optional parentResourceId only.' }
        $id = [string]$entry.resourceId
        if (-not $roster.ContainsKey($id) -or $seen.ContainsKey($id) -or $entry.layer -notin @('parent', 'guest', 'standalone')) {
            throw 'Topology must reference a unique selected resource and explicit parent/guest/standalone layer.'
        }
        $seen[$id] = $true
        $parent = if ('parentResourceId' -in $keys) { [string]$entry.parentResourceId } else { '' }
        if ($entry.layer -eq 'guest') {
            if (-not $roster.ContainsKey($parent) -or $parent -eq $id) { throw 'Guest requires a different selected parent identity.' }
        } elseif ($parent) { throw 'Only guests may declare a parentResourceId.' }
        $roster[$id].layer = $entry.layer
        $roster[$id].parentResourceId = $parent.ToLowerInvariant()
    }
    foreach ($row in $roster.Values) {
        if ($row.layer -eq 'guest' -and $roster[$row.parentResourceId].layer -ne 'parent') { throw 'Every guest parent must be explicitly classified as parent.' }
    }
    $scenario = '## Hypothetical scenario (optional)' + "`nNot configured. There is no price lookup, billed-cost or realised-savings claim."
    if ($HypotheticalHourlyRate -gt 0 -or $HypotheticalWeeklyHoursOff -gt 0 -or $HypotheticalMachineResourceId) {
        if ($HypotheticalHourlyRate -le 0 -or $HypotheticalWeeklyHoursOff -le 0 -or
            -not $roster.ContainsKey($HypotheticalMachineResourceId) -or
            $roster[$HypotheticalMachineResourceId].layer -notin @('parent', 'standalone')) {
            throw 'Scenario requires a positive rate/hours and one explicitly classified parent or standalone resource; no guest/double-counted scenario.'
        }
        $cost = Get-DemoOperationalScenario -HourlyRate $HypotheticalHourlyRate -WeeklyHoursOff $HypotheticalWeeklyHoursOff
        $rate = $cost.HourlyRate.ToString('0.######', [cultureinfo]::InvariantCulture)
        $amount = $cost.HypotheticalAvoidedCompute.ToString('0.######', [cultureinfo]::InvariantCulture)
        $scenario = "## Hypothetical scenario (operator inputs, not an action)`nOne resource only: $($roster[$HypotheticalMachineResourceId].resourceId). Assumed avoidable compute rate **$rate operator-currency units/hour** x **$HypotheticalWeeklyHoursOff hours/week** x **4 weeks** = **$amount hypothetical units**. Four weeks is not a calendar month. Inputs are not Azure prices, eligible billing hours, a proposed schedule or evidence it is safe to stop. Retained disks, network, monitoring, security, commitments, licences, taxes and other costs are excluded. No billed or realised savings; no combined parent/guest total."
    }
    $root = Join-Path $PSScriptRoot '..\..\workbooks'
    $data = @($roster.Values | Sort-Object resourceId) | ConvertTo-Json -Depth 5 -Compress -AsArray
    $prefix = "let Lookback = 1h * {LookbackHours};`nlet Machines = print Data = dynamic($data)`n| mv-expand Data`n| project ResourceId=tostring(Data.resourceId), Machine=tostring(Data.machine), Layer=tostring(Data.layer), ParentResourceId=tostring(Data.parentResourceId);`n"
    $series = Get-Content -LiteralPath (Join-Path $root 'queries\operational-series.kql') -Raw
    $summary = Get-Content -LiteralPath (Join-Path $root 'queries\operational-summary.kql') -Raw
    $baseQuery = $prefix + $series + "`n" + $summary + "`n"
    $queries = @{
        __SUMMARY__ = $baseQuery + 'Summary | order by Machine asc, Metric asc, Instance asc'
        __TREND__ = $prefix + $series + @'

Samples
| summarize Mean=avg(Value), P95=percentile(Value,95), Maximum=max(Value), Minimum=min(Value),
    ValidSamples=countif(isnotnull(Value)), InvalidSamples=countif(Invalid) by ResourceId, Metric, Instance, Hour=bin(TimeGenerated,1h)
| extend Mean=iff(isnan(Mean), real(null), Mean)
| join kind=inner Machines on ResourceId
| project Hour, ResourceId, Machine, Layer, ParentResourceId, Metric, Instance, Mean, P95, Maximum, Minimum, ValidSamples, InvalidSamples
| order by Machine asc, Metric asc, Instance asc, Hour asc
'@
        __CANDIDATES__ = $baseQuery + @'
Summary
| extend Review = case(Evidence != "Covered window - still review workload context", strcat("Evidence first: ", Evidence),
    Metric == "CPU percent" and Maximum >= 90, "CPU spike review (max >=90%); do not hide behind mean",
    Metric == "Committed percent" and Maximum >= 85, "Memory commitment pressure review (max >=85%)",
    Metric == "Available MB" and Minimum < 512, "Low available memory review (min <512 MB); not physical RAM sizing",
    Metric == "Disk free percent" and Minimum < 15, "Disk free-space pressure review (min <15%)",
    Metric == "CPU percent" and P95 < 20 and Maximum < 50, "Low sampled CPU conversation only; require memory/disk/I/O/business review; no sizing decision",
    "No threshold candidate in sampled metric; not a clearance")
| project Machine, ResourceId, Layer, ParentResourceId, Metric, Instance, Review, Mean, P95, Maximum, Minimum, FirstValue, LastValue, Delta, CoveragePercent, FirstSeen, LastSeen, Evidence
| order by Machine asc, Metric asc, Instance asc
'@
        __OWNERSHIP__ = 'Resources | where type =~ "microsoft.hybridcompute/machines" | where tolower(id) in (' +
            ((@($roster.Values | Sort-Object resourceId) | ForEach-Object { '"' + $_.resourceId + '"' }) -join ',') +
            ') | project ResourceId=tolower(id), Machine=name, Owner=tostring(tags.owner), CostCentre=tostring(tags.costcenter), Role=tostring(tags.role)' +
            ' | extend OwnershipReview=iff(isempty(Owner) or isempty(CostCentre), "Owner/cost-centre evidence missing - review", "Tags present - confirm accountability"), CheckedAtUtc=now() | order by Machine asc'
    }
    $file = if ($Purpose -eq 'capacity') { 'capacity-headroom.workbook.json' } else { 'optimisation-opportunities.workbook.json' }
    $book = Get-Content -LiteralPath (Join-Path $root $file) -Raw | ConvertFrom-Json -Depth 100
    $note = "Scope frozen at preparation $([datetime]::UtcNow.ToString('o')): $($roster.Count) explicit Arc IDs in $scope; workspace $WorkspaceResourceId. New hosts require a separately approved workbook refresh. Topology is operator-declared; absent declarations remain unclassified. No backing-VM duplicates or hardware capacity totals. Preparation does not prove telemetry is current."
    foreach ($item in $book.items) {
        if ($item.type -eq 3) {
            if (-not $queries.ContainsKey($item.content.query)) { throw 'Unknown operational query token.' }
            $item.content.query = $queries[$item.content.query]
            if ($item.content.queryType -eq 0) {
                $item.content | Add-Member -NotePropertyName crossComponentResources -NotePropertyValue @($WorkspaceResourceId.ToLowerInvariant())
                $item.content | Add-Member -NotePropertyName timeContext -NotePropertyValue @{ durationMs = 2592000000 }
            } else {
                $subscription = ($scope -split '/')[2]
                $item.content | Add-Member -NotePropertyName crossComponentResources -NotePropertyValue @("/subscriptions/$subscription")
            }
        } elseif ($item.type -eq 1) {
            if ($item.content.json -eq '__SCOPE_NOTE__') { $item.content.json = $note }
            if ($item.content.json -eq '__SCENARIO__') { $item.content.json = $scenario }
        }
    }
    $book.fallbackResourceIds = @($WorkspaceResourceId.ToLowerInvariant())
    $serialized = $book | ConvertTo-Json -Depth 100 -Compress
    if ($serialized -match '__[A-Z_]+__') { throw 'Unresolved workbook token; no deployment.' }
    $hash = [Security.Cryptography.SHA256]::HashData([text.encoding]::UTF8.GetBytes("$($WorkspaceResourceId.ToLowerInvariant())/$Purpose"))
    $name = [guid]::new([byte[]]$hash[0..15]).ToString()
    [pscustomobject]@{
        Name = $name
        ResourceId = "$scope/providers/Microsoft.Insights/workbooks/$name"
        DisplayName = if ($Purpose -eq 'capacity') { 'Capacity and headroom' } else { 'Optimisation opportunities' }
        SerializedData = $serialized
        Machines = @($roster.Values | Sort-Object resourceId)
    }
}

Export-ModuleMember -Function Get-DemoOperationalWorkbook, Get-DemoOperationalScenario
