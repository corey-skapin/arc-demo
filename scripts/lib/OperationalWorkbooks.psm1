#Requires -Version 7.4
Set-StrictMode -Version Latest

# Illustrative threshold policy. These are the workbook parameter defaults and the offline test values;
# they are triage heuristics shown in the workbook, not a DTF-approved service objective.
$script:OperationalDefaults = [ordered]@{
    CpuHigh = '80'
    SustainedMinutes = '30'
    MemHigh = '85'
    DiskLow = '15'
    LowCpuP95 = '20'
    # Deliberately modest so an on-demand lab is classifiable within hours of waking; production reviews would ask for more.
    MinObservedHours = '3'
    UtcOffsetHours = '0'
    SchedStartHour = 'none'
    SchedEndHour = 'none'
    SchedWeekendsOff = 'No'
    ScenarioBaseline = '0'
    ScenarioSharePct = 'none'
}

$script:OperationalFragments = @{
    series = 'operational-series.kql'
    summary = 'operational-summary.kql'
    hosts = 'operational-hosts.kql'
    candidates = 'operational-candidates.kql'
    schedule = 'operational-schedule.kql'
    scenario = 'operational-scenario.kql'
}

function Get-DemoOperationalScenario {
    <#
    .SYNOPSIS
        Reference arithmetic for the labelled optional cost scenario. The workbook KQL must agree with it.
    .DESCRIPTION
        Illustrative only: only the eligible share of a user-supplied baseline scales with running hours.
        The week is a 168-hour cycle, not a calendar month; fixed, licensed, retained-storage, monitoring and
        security costs stay outside the reduction. No pricing lookup, billing data or realised-savings claim.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 1000000000)][decimal]$MonthlyBaseline = 0,
        [ValidateRange(0, 100)][decimal]$EligibleSharePercent = 0,
        [ValidateRange(0, 168)][decimal]$WeeklyHoursOff = 0
    )
    $eligible = $MonthlyBaseline * $EligibleSharePercent / 100
    $reduction = $eligible * $WeeklyHoursOff / 168
    [pscustomobject]@{
        MonthlyBaseline = $MonthlyBaseline
        EligibleSharePercent = $EligibleSharePercent
        WeeklyHoursOff = $WeeklyHoursOff
        EligibleBaseline = $eligible
        FixedBaseline = $MonthlyBaseline - $eligible
        IllustrativeReduction = $reduction
        IllustrativeBaselineAfter = $MonthlyBaseline - $reduction
    }
}

function Get-DemoMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $null
    }
    $property = @($Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name }) | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Get-DemoWorkbookScope {
    param([string]$WorkspaceResourceId)
    $workspacePattern = '^(/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._()-]+)/providers/Microsoft.OperationalInsights/workspaces/[A-Za-z0-9._()-]+$'
    if ($WorkspaceResourceId -notmatch $workspacePattern) { throw 'Expected an exact workspace resource ID.' }
    $Matches[1]
}

function ConvertTo-DemoRosterText {
    # Braces would be read as workbook parameters when the roster is embedded in KQL.
    param($Value, [string]$Default = '')
    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    if (-not $text) { return $Default }
    $text.Replace('{', '(').Replace('}', ')')
}

function Get-DemoFirstTag {
    param($Tags, [string[]]$Names)
    foreach ($name in $Names) {
        $value = ConvertTo-DemoRosterText (Get-DemoMember $Tags $name)
        if ($value) { return $value }
    }
    ''
}

function ConvertTo-DemoNestedTopology {
    <#
    .SYNOPSIS
        Declares the optional nested guest from the private skin's nestedSqlGuest block.
    .DESCRIPTION
        Config-driven parent/guest layers for the roster. A guest that is not (yet) an Arc machine in the
        selected group is skipped with a warning; a disconnected guest is still declared. The guest runs inside
        its parent, so it is never an independent hardware capacity.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$NestedGuest,
        [Parameter(Mandatory)][object[]]$Machines,
        [Parameter(Mandatory)][string]$WorkspaceResourceId
    )
    if (-not $NestedGuest) { return @() }
    $scope = Get-DemoWorkbookScope $WorkspaceResourceId
    $byName = @{}
    foreach ($machine in $Machines) { $byName[(([string]$machine.id -split '/')[-1]).ToLowerInvariant()] = ([string]$machine.id).ToLowerInvariant() }
    $parentName = ([string](Get-DemoMember $NestedGuest 'ParentVmName')).ToLowerInvariant()
    $guestName = ([string](Get-DemoMember $NestedGuest 'ArcMachineName')).ToLowerInvariant()
    if (-not $byName.ContainsKey($parentName)) {
        Write-Warning "Nested guest parent '$parentName' is not an Arc machine in $scope; the guest is not added to the workbook roster."
        return @()
    }
    if (-not $byName.ContainsKey($guestName)) {
        Write-Warning "Nested guest Arc machine '$guestName' is not present yet; it is added after Arc onboarding and a workbook refresh."
        return @()
    }
    @(
        @{ resourceId = $byName[$parentName]; layer = 'parent' }
        @{ resourceId = $byName[$guestName]; layer = 'guest'; parentResourceId = $byName[$parentName] }
    )
}

function Get-DemoOperationalRoster {
    <#
    .SYNOPSIS
        Builds the exact, bounded Arc roster: identity, declared topology and published tags.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][object[]]$Machines,
        [object[]]$Topology = @()
    )
    $scope = Get-DemoWorkbookScope $WorkspaceResourceId
    $machinePattern = '^' + [regex]::Escape("$scope/providers/Microsoft.HybridCompute/machines/") + '[A-Za-z0-9._()-]+$'
    # Every item query embeds the roster, so the cap also keeps each composed query well inside the Log Analytics request limit.
    if ($Machines.Count -lt 1 -or $Machines.Count -gt 50) { throw 'Select 1-50 exact Arc resources, not an unbounded estate.' }
    $roster = @{}
    foreach ($machine in $Machines) {
        $id = [string](Get-DemoMember $machine 'id')
        if ($id -notmatch $machinePattern -or $roster.ContainsKey($id.ToLowerInvariant())) { throw 'Foreign, malformed or duplicate Arc identity in workbook roster.' }
        $tags = Get-DemoMember $machine 'tags'
        $detected = Get-DemoMember $machine 'detectedProperties'
        $osHint = "$(Get-DemoMember $machine 'osType') $(Get-DemoMember $machine 'osName')"
        $os = if ($osHint -match 'linux') { 'Linux' } elseif ($osHint -match 'windows') { 'Windows' } else { 'Unknown' }
        $vcpu = 0
        [void][int]::TryParse([string](Get-DemoMember $detected 'logicalCoreCount'), [ref]$vcpu)
        $memory = 0.0
        [void][double]::TryParse([string](Get-DemoMember $detected 'totalPhysicalMemoryInGigabytes'), [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$memory)
        $roster[$id.ToLowerInvariant()] = [ordered]@{
            resourceId = $id.ToLowerInvariant()
            machine = ($id -split '/')[-1]
            layer = 'unclassified'
            parentResourceId = ''
            os = $os
            environment = (Get-DemoFirstTag $tags @('env', 'environment')) -replace '^$', '(untagged)'
            application = (Get-DemoFirstTag $tags @('application', 'app', 'workload', 'role')) -replace '^$', '(untagged)'
            owner = Get-DemoFirstTag $tags @('owner')
            costCentre = Get-DemoFirstTag $tags @('costcenter', 'costcentre')
            vcpu = $vcpu
            memoryGb = [math]::Round($memory, 1)
        }
    }
    $seen = @{}
    foreach ($entry in $Topology) {
        $keys = @($entry.PSObject.Properties.Name)
        if ($entry -is [System.Collections.IDictionary]) { $keys = @($entry.Keys) }
        if (@($keys | Where-Object { $_ -notin @('resourceId', 'layer', 'parentResourceId') }).Count -or
            'resourceId' -notin $keys -or 'layer' -notin $keys) { throw 'Topology requires resourceId/layer and optional parentResourceId only.' }
        $id = ([string](Get-DemoMember $entry 'resourceId')).ToLowerInvariant()
        $layer = [string](Get-DemoMember $entry 'layer')
        if (-not $roster.ContainsKey($id) -or $seen.ContainsKey($id) -or $layer -notin @('parent', 'guest', 'standalone')) {
            throw 'Topology must reference a unique selected resource and explicit parent/guest/standalone layer.'
        }
        $seen[$id] = $true
        $parent = if ('parentResourceId' -in $keys) { ([string](Get-DemoMember $entry 'parentResourceId')).ToLowerInvariant() } else { '' }
        if ($layer -eq 'guest') {
            if (-not $roster.ContainsKey($parent) -or $parent -eq $id) { throw 'Guest requires a different selected parent identity.' }
        } elseif ($parent) { throw 'Only guests may declare a parentResourceId.' }
        $roster[$id].layer = $layer
        $roster[$id].parentResourceId = $parent
    }
    foreach ($row in $roster.Values) {
        if ($row.layer -eq 'guest' -and $roster[$row.parentResourceId].layer -ne 'parent') { throw 'Every guest parent must be explicitly classified as parent.' }
    }
    @($roster.Values | Sort-Object resourceId)
}

function Get-DemoOperationalPreamble {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Roster)
    $data = $Roster | ConvertTo-Json -Depth 5 -Compress -AsArray
    @"
let AllMachines = print Data = dynamic($data)
| mv-expand Data
| project ResourceId = tostring(Data.resourceId), Machine = tostring(Data.machine), Layer = tostring(Data.layer), ParentResourceId = tostring(Data.parentResourceId),
    Os = tostring(Data.os), Environment = tostring(Data.environment), Application = tostring(Data.application),
    Owner = tostring(Data.owner), CostCentre = tostring(Data.costCentre), Vcpu = toint(Data.vcpu), MemoryGb = todouble(Data.memoryGb);
let OsFilter = dynamic([{OsFilter}]);
let EnvironmentFilter = dynamic([{EnvironmentFilter}]);
let ApplicationFilter = dynamic([{ApplicationFilter}]);
let OsAll = array_length(OsFilter) == 0 or set_has_element(OsFilter, 'value::all') or set_has_element(OsFilter, '*');
let EnvironmentAll = array_length(EnvironmentFilter) == 0 or set_has_element(EnvironmentFilter, 'value::all') or set_has_element(EnvironmentFilter, '*');
let ApplicationAll = array_length(ApplicationFilter) == 0 or set_has_element(ApplicationFilter, 'value::all') or set_has_element(ApplicationFilter, '*');
let Machines = AllMachines
| where (OsAll or Os in (OsFilter))
| where (EnvironmentAll or Environment in (EnvironmentFilter))
| where (ApplicationAll or Application in (ApplicationFilter));
let WindowStart = todatetime('{TimeRange:startISO}');
let WindowEnd = todatetime('{TimeRange:endISO}');
let CpuHigh = {CpuHigh};
let SustainedMinutes = {SustainedMinutes};
let MemHigh = {MemHigh};
let DiskLow = {DiskLow};
let LowCpuP95 = {LowCpuP95};
let MinObservedHours = {MinObservedHours};
let WindowSpan = WindowEnd - WindowStart;
let Step = case(WindowSpan <= 6h, 5m, WindowSpan <= 2d, 30m, WindowSpan <= 8d, 1h, WindowSpan <= 16d, 2h, 6h);
// Column charts need fewer, wider intervals than a line: BarStep for several machines side by side, DetailStep for one machine.
let BarStep = case(WindowSpan <= 6h, 30m, WindowSpan <= 2d, 2h, WindowSpan <= 8d, 12h, WindowSpan <= 16d, 1d, 2d);
let DetailStep = case(WindowSpan <= 6h, 10m, WindowSpan <= 2d, 1h, WindowSpan <= 8d, 2h, WindowSpan <= 16d, 6h, 12h);
let Num = (v:real, digits:int) { replace_regex(tostring(round(v, digits)), @"\.0+`$", "") };

"@
}

function Read-DemoOperationalQueryFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Shared workbook query not found: $(Split-Path $Path -Leaf)" }
    $text = Get-Content -LiteralPath $Path -Raw
    $includes = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^//\s*include:\s*(?<names>.+)$') { $includes += @($Matches.names -split '[,\s]+' | Where-Object { $_ }) }
        elseif ($line -notmatch '^//' -and $line.Trim()) { break }
    }
    [pscustomobject]@{ Includes = $includes; Text = $text }
}

function Get-DemoOperationalQuery {
    <#
    .SYNOPSIS
        Composes one workbook query from the roster preamble, the shared fragments it includes and its own body.
    .DESCRIPTION
        {Parameter} placeholders stay in the text for the workbook to substitute. Fragments are the single source
        of truth shared by both workbooks, so identical scope and window give identical metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Roster,
        [string]$QueryRoot = (Join-Path $PSScriptRoot '..\..\workbooks\queries')
    )
    $ordered = [System.Collections.Generic.List[string]]::new()
    $visit = $null
    $visit = {
        param($fragmentName, $stack)
        if ($fragmentName -in $stack) { throw "Circular shared query include: $fragmentName" }
        if (-not $script:OperationalFragments.ContainsKey($fragmentName)) { throw "Unknown shared query include: $fragmentName" }
        $file = Read-DemoOperationalQueryFile (Join-Path $QueryRoot $script:OperationalFragments[$fragmentName])
        foreach ($child in $file.Includes) { & $visit $child @($stack + $fragmentName) }
        if ($fragmentName -notin $ordered) { $ordered.Add($fragmentName) }
    }
    if ($Name -notmatch '^[a-z][a-z0-9-]*$') { throw 'Invalid shared query name.' }
    $item = Read-DemoOperationalQueryFile (Join-Path $QueryRoot "$Name.kql")
    foreach ($include in $item.Includes) { & $visit $include @() }
    $ids = ($Roster | ForEach-Object { '"' + $_.resourceId + '"' }) -join ', '
    $parts = @((Get-DemoOperationalPreamble -Roster $Roster))
    foreach ($fragmentName in $ordered) {
        $parts += (Read-DemoOperationalQueryFile (Join-Path $QueryRoot $script:OperationalFragments[$fragmentName])).Text
    }
    $parts += $item.Text
    ($parts -join "`n").Replace('__ROSTER_IDS__', $ids)
}

function Get-DemoOperationalArgQuery {
    # Resource Graph items are standalone; only the exact roster IDs are injected.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Roster,
        [string]$QueryRoot = (Join-Path $PSScriptRoot '..\..\workbooks\queries')
    )
    if ($Name -notmatch '^[a-z][a-z0-9-]*$') { throw 'Invalid shared query name.' }
    $ids = ($Roster | ForEach-Object { '"' + $_.resourceId + '"' }) -join ', '
    (Read-DemoOperationalQueryFile (Join-Path $QueryRoot "$Name.kql")).Text.Replace('__ROSTER_IDS__', $ids)
}

function Expand-DemoOperationalQuery {
    <#
    .SYNOPSIS
        Offline substitution of workbook {Parameter} placeholders so a query can be executed read-only for tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][object[]]$Roster,
        [hashtable]$Parameters = @{},
        [datetime]$Start = ([datetime]::UtcNow.AddDays(-14)),
        [datetime]$End = ([datetime]::UtcNow)
    )
    $quoted = { param($values) (@($values | Sort-Object -Unique | ForEach-Object { "'" + ([string]$_).Replace("'", "\'") + "'" }) -join ',') }
    $iso = { param([datetime]$value) $value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) }
    $values = [ordered]@{
        'TimeRange:startISO' = & $iso $Start
        'TimeRange:endISO' = & $iso $End
        OsFilter = & $quoted @($Roster | ForEach-Object { $_.os })
        EnvironmentFilter = & $quoted @($Roster | ForEach-Object { $_.environment })
        ApplicationFilter = & $quoted @($Roster | ForEach-Object { $_.application })
        SelectedHost = ''
        SelectedCandidate = ''
    }
    foreach ($key in $script:OperationalDefaults.Keys) { $values[$key] = $script:OperationalDefaults[$key] }
    foreach ($key in $Parameters.Keys) { $values[$key] = [string]$Parameters[$key] }
    $result = $Query
    foreach ($key in $values.Keys) { $result = $result.Replace('{' + $key + '}', [string]$values[$key]) }
    $unresolved = [regex]::Match($result, '\{[A-Za-z][A-Za-z0-9]*(:[A-Za-z]+)?\}')
    if ($unresolved.Success) { throw "Unresolved workbook parameter placeholder $($unresolved.Value) in an offline query." }
    $result
}

function Get-DemoOperationalOptions {
    param([object[]]$Roster, [string]$Kind)
    $values = switch ($Kind) {
        'os' { @($Roster | ForEach-Object { $_.os }) }
        'environment' { @($Roster | ForEach-Object { $_.environment }) }
        'application' { @($Roster | ForEach-Object { $_.application }) }
        'hosts' { @($Roster | ForEach-Object { $_.machine }) }
        default { throw "Unknown option list $Kind." }
    }
    $options = @($values | Sort-Object -Unique | ForEach-Object { [ordered]@{ value = [string]$_; label = [string]$_ } })
    # One object at a time, joined by hand: ConvertTo-Json -InputObject <array> -AsArray wraps the array in a second
    # array on current PowerShell 7 builds, and the portal then sees a single unusable option and cannot expand All.
    '[' + (@($options | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress }) -join ',') + ']'
}

function Update-DemoTemplateNode {
    # Recursively resolves deploy-time tokens in a loaded workbook template.
    param($Node, [hashtable]$Context)
    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            if ($Node[$i] -is [string]) { $Node[$i] = Resolve-DemoTemplateString $Node[$i] $Context } else { Update-DemoTemplateNode $Node[$i] $Context }
        }
        return
    }
    if ($Node -isnot [pscustomobject]) { return }
    foreach ($property in @($Node.PSObject.Properties)) {
        if ($property.Value -is [string]) { $property.Value = Resolve-DemoTemplateString $property.Value $Context }
        else { Update-DemoTemplateNode $property.Value $Context }
    }
    if (($Node.PSObject.Properties.Name -contains 'type') -and $Node.type -eq 3 -and ($Node.PSObject.Properties.Name -contains 'content')) {
        Update-DemoTemplateQuery $Node.content $Context
    }
}

function Resolve-DemoTemplateString {
    param([string]$Text, [hashtable]$Context)
    if ($Text -notmatch '__') { return $Text }
    $result = $Text
    foreach ($key in $Context.Tokens.Keys) { $result = $result.Replace("__${key}__", [string]$Context.Tokens[$key]) }
    $result = [regex]::Replace($result, '__OPTIONS:(?<kind>[a-z]+)__', { param($m) Get-DemoOperationalOptions -Roster $Context.Roster -Kind $m.Groups['kind'].Value })
    [regex]::Replace($result, '__DEFAULT:(?<name>[A-Za-z0-9]+)__', {
        param($m)
        $name = $m.Groups['name'].Value
        if ($Context.Defaults.Contains($name)) { [string]$Context.Defaults[$name] } else { throw "Unknown default token $name." }
    })
}

function Update-DemoTemplateQuery {
    param($Content, [hashtable]$Context)
    if ($Content.query -notmatch '^__QUERY:(?<name>[a-z][a-z0-9-]*)__$') { return }
    $name = $Matches.name
    if ($Content.queryType -eq 1) {
        $Content.query = Get-DemoOperationalArgQuery -Name $name -Roster $Context.Roster -QueryRoot $Context.QueryRoot
        $subscription = ($Context.Scope -split '/')[2]
        $Content | Add-Member -NotePropertyName crossComponentResources -NotePropertyValue @("/subscriptions/$subscription") -Force
    } else {
        $Content.query = Get-DemoOperationalQuery -Name $name -Roster $Context.Roster -QueryRoot $Context.QueryRoot
        $Content | Add-Member -NotePropertyName crossComponentResources -NotePropertyValue @($Context.Workspace) -Force
    }
}

function Get-DemoTemplateQueryItem {
    # Every query item of a workbook template, including the ones inside tab groups.
    param($Items)
    foreach ($item in @($Items)) {
        if ($item.type -eq 3) { $item }
        elseif ($item.type -eq 12) { Get-DemoTemplateQueryItem $item.content.items }
    }
}

function Set-DemoJsonProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function New-DemoGridColumn {
    # One grid column formatter. Widths are proportional fr units, so a grid fits any container instead of pushing columns off screen.
    # A column may ask for fixed characters (ch) instead: the narrow cells of a heat map cannot shrink below the portal's minimum for a flexible column.
    param([Parameter(Mandatory)]$Column, [Parameter(Mandatory)][string]$Name, $TemplateFormatter)
    $unit = if ($Column.PSObject.Properties.Name -contains 'unit') { [string]$Column.unit } else { 'fr' }
    if ($unit -notin 'fr', 'ch') { throw "Unknown width unit '$unit' for column $Name." }
    $width = "$([int]$Column.width)$unit"
    $percent = [ordered]@{ unit = 1; options = [ordered]@{ style = 'decimal'; maximumFractionDigits = 1 } }
    switch ($Column.kind) {
        'text' {
            [ordered]@{ columnMatch = $Name; formatter = 1; formatOptions = [ordered]@{ customColumnWidthSetting = $width } }
        }
        'num' {
            $digits = [int]$Column.decimals
            $formatter = [ordered]@{ columnMatch = $Name; formatter = 1; formatOptions = [ordered]@{ customColumnWidthSetting = $width } }
            # A whole number needs no format (the Count unit abbreviates 3,000 to "3 K"); a fraction is capped at the stated decimals and never padded, so 52 reads 52 like the text beside it.
            if ($digits -gt 0) {
                $formatter.numberFormat = [ordered]@{ unit = 0; options = [ordered]@{ style = 'decimal'; useGrouping = $false; minimumFractionDigits = 0; maximumFractionDigits = $digits } }
            }
            $formatter
        }
        'pct' {
            [ordered]@{
                columnMatch = $Name; formatter = 8
                formatOptions = [ordered]@{ palette = [string]$Column.palette; min = 0; max = 100; customColumnWidthSetting = $width }
                numberFormat = $percent
            }
        }
        'heat' {
            [ordered]@{ columnMatch = $Name; formatter = 8; formatOptions = [ordered]@{ palette = [string]$Column.palette; min = 0; max = 100; customColumnWidthSetting = $width } }
        }
        'spark' {
            [ordered]@{ columnMatch = $Name; formatter = 10; formatOptions = [ordered]@{ palette = 'blue'; customColumnWidthSetting = $width } }
        }
        'date' {
            if ([int]$Column.width -lt 26) { throw "Date column $Name needs at least 26fr so the clock is not clipped." }
            [ordered]@{
                columnMatch = $Name; formatter = 6; formatOptions = [ordered]@{ customColumnWidthSetting = $width }
                dateFormat = [ordered]@{ showUtcTime = $null; formatName = 'shortDateTimeNoMsPattern' }
            }
        }
        'status' {
            if ($Column.PSObject.Properties.Name -contains 'rules') {
                $grid = @(foreach ($rule in $Column.rules) { [ordered]@{ operator = '=='; thresholdValue = [string]$rule.value; representation = [string]$rule.representation; text = '{0}{1}' } }) +
                    [ordered]@{ operator = 'Default'; thresholdValue = $null; representation = [string]$Column.default; text = '{0}{1}' }
                [ordered]@{
                    columnMatch = $Name; formatter = 18
                    formatOptions = [ordered]@{ thresholdsOptions = [string]$Column.options; thresholdsGrid = $grid; customColumnWidthSetting = $width }
                }
            } else {
                if (-not $TemplateFormatter) { throw "Status column $Name has neither colour rules in the layout nor a threshold formatter in the template." }
                Set-DemoJsonProperty $TemplateFormatter.formatOptions 'customColumnWidthSetting' $width
                $TemplateFormatter
            }
        }
        default { throw "Unknown grid column kind '$($Column.kind)' for $Name." }
    }
}

function Set-DemoTableLayout {
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)]$Table)
    $old = $Content.PSObject.Properties['gridSettings']
    $grid = if ($old -and $old.Value) { $old.Value } else { [pscustomobject]@{} }
    $thresholds = @{}
    $existing = $grid.PSObject.Properties['formatters']
    foreach ($formatter in $(if ($existing) { @($existing.Value) } else { @() })) {
        if ($formatter -and $formatter.formatter -eq 18) { $thresholds[[string]$formatter.columnMatch] = $formatter }
    }
    $formatters = [System.Collections.Generic.List[object]]::new()
    $labels = [System.Collections.Generic.List[object]]::new()
    foreach ($column in $Table.columns) {
        $hasRepeat = $column.PSObject.Properties.Name -contains 'repeat'
        $expanded = if ($hasRepeat) {
            # A repeated column may cover several hours (span): {0} is the block number, {1} its first hour and {2} its last, so a two-hour block reads 00-01, 02-03 and so on.
            $span = if ($column.repeat.PSObject.Properties.Name -contains 'span') { [int]$column.repeat.span } else { 1 }
            if ($span -lt 1) { throw "Repeat span for $($column.repeat.name) must be at least 1." }
            @($column.repeat.from..$column.repeat.to | ForEach-Object {
                    $first = $_ * $span
                    @{ Name = [string]::Format($column.repeat.name, $_); Label = [string]::Format($column.repeat.label, $_, $first, $first + $span - 1) }
                })
        } else {
            @(@{ Name = [string]$column.name; Label = $(if ($column.PSObject.Properties.Name -contains 'label') { [string]$column.label } else { '' }) })
        }
        foreach ($entry in $expanded) {
            $formatters.Add((New-DemoGridColumn -Column $column -Name $entry.Name -TemplateFormatter $thresholds[$entry.Name]))
            if ($entry.Label) { $labels.Add([ordered]@{ columnId = $entry.Name; label = $entry.Label }) }
        }
    }
    $filter = if ($grid.PSObject.Properties['filter']) { $grid.filter } else { $false }
    Set-DemoJsonProperty $grid 'formatters' $formatters.ToArray()
    Set-DemoJsonProperty $grid 'filter' $filter
    Set-DemoJsonProperty $grid 'labelSettings' $labels.ToArray()
    Set-DemoJsonProperty $Content 'gridSettings' $grid
    Set-DemoJsonProperty $Content 'visualization' 'table'
    Set-DemoJsonProperty $Content 'size' ([int]$Table.size)
}

function Set-DemoChartLayout {
    # Column charts for time series: an interval with no samples is a blank column, never a zero or an interpolated line, and the legend carries no (Sum) totals.
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)]$Chart)
    if ($Chart.PSObject.Properties.Name -contains 'keep') {
        Set-DemoJsonProperty $Content.chartSettings 'showMetrics' $false
        return
    }
    $y = [ordered]@{ min = 0 }
    if ($Chart.axis -eq 'percent') {
        $y.max = 100
        $y.numberFormatSettings = [ordered]@{ unit = 1; options = [ordered]@{ style = 'decimal'; useGrouping = $true; maximumFractionDigits = 1 } }
    } else {
        $y.numberFormatSettings = [ordered]@{ unit = 0; options = [ordered]@{ style = 'decimal'; useGrouping = $true; maximumFractionDigits = 0 } }
    }
    $settings = [ordered]@{ showLegend = [bool]$Chart.legend; showMetrics = $false }
    if ($Chart.PSObject.Properties.Name -contains 'series') {
        $settings.seriesLabelSettings = @(foreach ($series in $Chart.series) { [ordered]@{ seriesName = [string]$series.name; label = [string]$series.label; color = [string]$series.color } })
    }
    $settings.ySettings = $y
    if ($Chart.PSObject.Properties.Name -contains 'threshold') {
        $settings.customThresholdLine = [string]$Chart.threshold
        $settings.customThresholdLineStyle = 1
    }
    Set-DemoJsonProperty $Content 'visualization' ([string]$Chart.visualization)
    Set-DemoJsonProperty $Content 'chartSettings' ([pscustomobject]$settings)
}

function Set-DemoTileLayout {
    # Count tiles carry no palette colour (a bar colour must mean something); text-valued tiles show their value as text.
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)]$Tiles)
    $left = if ($Tiles.value -eq 'number') { [ordered]@{ columnMatch = 'Value'; formatter = 12; formatOptions = [ordered]@{ palette = 'none' } } } else { [ordered]@{ columnMatch = 'Value'; formatter = 1 } }
    $settings = [ordered]@{
        titleContent = [ordered]@{ columnMatch = 'Label'; formatter = 1 }
        leftContent = $left
        secondaryContent = [ordered]@{ columnMatch = 'Note'; formatter = 1 }
        showBorder = $true
    }
    if ($Tiles.PSObject.Properties.Name -contains 'size') { $settings.size = [string]$Tiles.size }
    Set-DemoJsonProperty $Content 'visualization' 'tiles'
    Set-DemoJsonProperty $Content 'tileSettings' ([pscustomobject]$settings)
}

function Set-DemoOperationalLayout {
    <#
    .SYNOPSIS
        Applies the portal layout (workbooks/operational-layout.json) to a loaded workbook template: grid widths and formats, sizes, charts and tiles.
    .DESCRIPTION
        Every query item must have exactly one layout entry and every entry must name a query item, so a new tile cannot ship without a layout.
        Status columns keep the colour rules written in the template.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Items, [Parameter(Mandatory)]$Layout)
    $queryItems = @(Get-DemoTemplateQueryItem $Items)
    $duplicate = $queryItems | Group-Object name | Where-Object Count -gt 1 | Select-Object -First 1
    if ($duplicate) { throw "Workbook item name is not unique: $($duplicate.Name)." }
    $byName = @{}
    foreach ($item in $queryItems) { $byName[[string]$item.name] = $item }
    $entries = @($Layout.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $byName.Keys) { if ($name -notin $entries) { throw "Layout has no entry for workbook item $name." } }
    foreach ($name in $entries) {
        if (-not $byName.ContainsKey($name)) { throw "Layout entry $name is not a query item of this workbook." }
        $item = $byName[$name]
        $entry = $Layout.$name
        $keys = @($entry.PSObject.Properties.Name)
        if ('customWidth' -in $keys) { Set-DemoJsonProperty $item 'customWidth' ([string]$entry.customWidth) }
        if ('table' -in $keys) { Set-DemoTableLayout -Content $item.content -Table $entry.table }
        if ('chart' -in $keys) { Set-DemoChartLayout -Content $item.content -Chart $entry.chart }
        if ('tiles' -in $keys) { Set-DemoTileLayout -Content $item.content -Tiles $entry.tiles }
    }
}

function Get-DemoOperationalWorkbookIdentity {
    <#
    .SYNOPSIS
        The deterministic workbook name, ARM ID and display name for a purpose, derived from the workspace only.
    .DESCRIPTION
        Needs no Arc inventory, so a draft can still be removed after the roster is gone or unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [switch]$Draft
    )
    $scope = Get-DemoWorkbookScope $WorkspaceResourceId
    $seed = "$($WorkspaceResourceId.ToLowerInvariant())/$Purpose" + $(if ($Draft) { '/draft' } else { '' })
    $hash = [Security.Cryptography.SHA256]::HashData([text.encoding]::UTF8.GetBytes($seed))
    $name = [guid]::new([byte[]]$hash[0..15]).ToString()
    $title = if ($Purpose -eq 'capacity') { 'Capacity and headroom' } else { 'Optimisation opportunities' }
    [pscustomobject]@{
        Name = $name
        ResourceId = "$scope/providers/Microsoft.Insights/workbooks/$name"
        DisplayName = if ($Draft) { "$title (draft)" } else { $title }
    }
}

function Get-DemoOperationalWorkbookLink {
    <#
    .SYNOPSIS
        Portal hyperlink to the sibling workbook for the text items: a draft links to the draft, a published workbook to the published one.
    .DESCRIPTION
        Plain navigation only; the target keeps its own default scope. Both workbooks must be published for the link to resolve.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [switch]$Draft,
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId = ''
    )
    $target = Get-DemoOperationalWorkbookIdentity -Purpose $Purpose -WorkspaceResourceId $WorkspaceResourceId -Draft:$Draft
    $root = if ($TenantId) { "https://portal.azure.com/#@$TenantId/resource" } else { 'https://portal.azure.com/#resource' }
    # Parentheses are legal in resource group names but would end a markdown link early.
    ($root + $target.ResourceId + '/workbook').Replace('(', '%28').Replace(')', '%29')
}

function Get-DemoUtcOffsetLabel {
    <#
    .SYNOPSIS
        Text label for a display offset in hours: UTC, UTC+10:30, UTC-5.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][decimal]$Hours)
    if ($Hours -eq 0) { return 'UTC' }
    $span = [timespan]::FromHours([double][math]::Abs($Hours))
    'UTC' + $(if ($Hours -gt 0) { '+' } else { '-' }) + $(if ($span.Minutes) { $span.ToString('h\:mm') } else { $span.Hours.ToString() })
}

function Get-DemoOperationalWorkbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('capacity', 'optimisation')][string]$Purpose,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][object[]]$Machines,
        [object[]]$Topology = @(),
        [switch]$Draft,
        [ValidateRange(-12, 14)][decimal]$DisplayUtcOffsetHours = 0,
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$TenantId = ''
    )
    $scope = Get-DemoWorkbookScope $WorkspaceResourceId
    $identity = Get-DemoOperationalWorkbookIdentity -Purpose $Purpose -WorkspaceResourceId $WorkspaceResourceId -Draft:$Draft
    $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $WorkspaceResourceId -Machines $Machines -Topology $Topology)
    $root = Join-Path $PSScriptRoot '..\..\workbooks'
    $file = if ($Purpose -eq 'capacity') { 'capacity-headroom.workbook.json' } else { 'optimisation-opportunities.workbook.json' }
    $book = Get-Content -LiteralPath (Join-Path $root $file) -Raw | ConvertFrom-Json -Depth 100
    $prepared = [datetime]::UtcNow.AddHours([double]$DisplayUtcOffsetHours).ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) + ' (' + (Get-DemoUtcOffsetLabel -Hours $DisplayUtcOffsetHours) + ')'
    $guests = @($roster | Where-Object layer -eq 'guest').Count
    $note = "Roster and tags published $prepared for $($roster.Count) exact Arc IDs in this resource group ($guests declared guest(s)). Refresh by republishing to add hosts or pick up tag changes. Topology is operator-declared; undeclared machines stay unclassified. Parent and guest rows are separate observations and never hardware totals. Check telemetry timestamps before relying on any figure."
    $defaults = [ordered]@{}
    foreach ($key in $script:OperationalDefaults.Keys) { $defaults[$key] = $script:OperationalDefaults[$key] }
    $defaults['UtcOffsetHours'] = $DisplayUtcOffsetHours.ToString('0.##', [cultureinfo]::InvariantCulture)
    $context = @{
        Roster = $roster; Scope = $scope; Workspace = $WorkspaceResourceId.ToLowerInvariant(); QueryRoot = (Join-Path $root 'queries')
        Defaults = $defaults
        Tokens = @{
            SCOPE_NOTE = $note; PREPARED = $prepared
            LINK_CAPACITY = (Get-DemoOperationalWorkbookLink -Purpose capacity -WorkspaceResourceId $WorkspaceResourceId -Draft:$Draft -TenantId $TenantId)
            LINK_OPTIMISATION = (Get-DemoOperationalWorkbookLink -Purpose optimisation -WorkspaceResourceId $WorkspaceResourceId -Draft:$Draft -TenantId $TenantId)
        }
    }
    if (-not $Draft) {
        $book.items = @($book.items | Where-Object { $_.name -ne 'draft-banner' })
    }
    Update-DemoTemplateNode $book.items $context
    $layout = (Get-Content -LiteralPath (Join-Path $root 'operational-layout.json') -Raw | ConvertFrom-Json -Depth 20).$Purpose
    Set-DemoOperationalLayout -Items $book.items -Layout $layout
    $book.fallbackResourceIds = @($WorkspaceResourceId.ToLowerInvariant())
    $serialized = $book | ConvertTo-Json -Depth 100 -Compress
    if ($serialized -match '__(QUERY|OPTIONS|DEFAULT|SCOPE|PREPARED|ROSTER|LINK)[A-Z_]*(:[A-Za-z0-9_.-]+)?__') { throw 'Unresolved workbook token; no deployment.' }
    [pscustomobject]@{
        Name = $identity.Name
        ResourceId = $identity.ResourceId
        DisplayName = $identity.DisplayName
        SerializedData = $serialized
        Machines = $roster
        Draft = [bool]$Draft
    }
}

Export-ModuleMember -Function Get-DemoOperationalWorkbook, Get-DemoOperationalWorkbookIdentity, Get-DemoOperationalWorkbookLink, Get-DemoOperationalScenario, Get-DemoOperationalRoster,
    ConvertTo-DemoNestedTopology, Get-DemoOperationalQuery, Get-DemoOperationalArgQuery, Expand-DemoOperationalQuery, Get-DemoUtcOffsetLabel
