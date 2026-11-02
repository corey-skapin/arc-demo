param(
    [string]$WorkspaceResourceId = '',
    [guid]$SubscriptionId,
    [guid]$TenantId
)

BeforeAll {
    $script:TabNames = @('load', 'events', 'changes', 'posture', 'detail', 'method')
    $repo = Split-Path $PSScriptRoot
    $script:TemplatePath = Join-Path $repo 'workbooks/arc-demo-overview.workbook.json'
    $script:Raw = Get-Content -LiteralPath $script:TemplatePath -Raw
    $script:Book = $script:Raw | ConvertFrom-Json -Depth 100
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    $script:All = @(Get-WorkbookItem $script:Book.items)
    $script:Queries = @($script:All | Where-Object { $_.type -eq 3 })
    $script:LogQueries = @($script:Queries | Where-Object { $_.content.queryType -eq 0 })
    $script:GraphQueries = @($script:Queries | Where-Object { $_.content.queryType -eq 1 })
    $script:Parameters = @($script:All | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
    function Get-Query([string]$Name) { ($script:Queries | Where-Object name -eq $Name).content.query }
    function Get-Item([string]$Name) { ($script:Queries | Where-Object name -eq $Name).content }
}

Describe 'Estate Overview is a static, self-contained workbook template' {
    It 'is a Notebook/1.0 workbook with no deploy-time token, subscription path or identity' {
        $script:Book.version | Should -Be 'Notebook/1.0'
        $script:Raw | Should -Not -Match '__[A-Z]+(:[A-Za-z]+)?__'
        $script:Raw | Should -Not -Match '/subscriptions/'
        $script:Raw | Should -Not -Match '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'
        $script:Raw | Should -Not -Match ([string][char]0xFFFD)
    }

    It 'uses only the parameters the workbook defines' {
        $known = @('TimeRange:startISO', 'TimeRange:endISO', 'OsFilter', 'EnvironmentFilter', 'RoleFilter', 'MachineScope', 'AlertSummary', 'SelectedMachine')
        $texts = @($script:Queries | ForEach-Object { [pscustomobject]@{ Name = $_.name; Query = $_.content.query } }) +
            @($script:Parameters | Where-Object { $_.query } | ForEach-Object { [pscustomobject]@{ Name = "parameter $($_.name)"; Query = $_.query } })
        foreach ($entry in $texts) {
            foreach ($match in [regex]::Matches($entry.Query, '\{([A-Za-z][A-Za-z0-9]*(?::[A-Za-z]+)?)\}')) {
                $match.Groups[1].Value | Should -BeIn $known -Because "$($entry.Name) uses {$($match.Groups[1].Value)}"
            }
        }
    }

    It 'defines no Log Analytics time context, so the 14-day heartbeat lookback is not cut to the time range' {
        foreach ($item in $script:LogQueries) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'timeContextFromParameter' -Because $item.name }
    }
}

Describe 'Estate Overview opens with data and zero clicks' {
    It 'gives every parameter a working default' {
        $script:Parameters.Count | Should -Be 6
        ($script:Parameters | Where-Object name -eq 'TimeRange').value.durationMs | Should -Be 86400000
        foreach ($name in 'OsFilter', 'EnvironmentFilter', 'RoleFilter', 'MachineScope', 'AlertSummary') {
            $p = $script:Parameters | Where-Object name -eq $name
            @($p.value) | Should -Be @('value::all') -Because $name
            $p.defaultValue | Should -Be 'value::all' -Because $name
        }
    }

    It 'builds the static operating-system options as a flat array of option objects' {
        $p = $script:Parameters | Where-Object name -eq 'OsFilter'
        $p.jsonData | Should -Match '^\[\{'
        $options = @($p.jsonData | ConvertFrom-Json)
        $options.Count | Should -Be 2
        foreach ($option in $options) { $option.value | Should -Not -BeNullOrEmpty; $option.label | Should -Not -BeNullOrEmpty }
        @($options.value) | Should -Contain 'Windows'
        @($options.value) | Should -Contain 'Linux'
    }

    It 'reads the environment and role options from live Arc tags, with an untagged bucket, across all subscriptions like the official dropdowns' {
        foreach ($name in 'EnvironmentFilter', 'RoleFilter') {
            $p = $script:Parameters | Where-Object name -eq $name
            $p.queryType | Should -Be 1
            $p.resourceType | Should -Be 'microsoft.resourcegraph/resources'
            @($p.crossComponentResources) | Should -Be @('value::all') -Because $name
            $p.query | Should -Match "microsoft\.hybridcompute/machines"
            $p.query | Should -Match "'\(untagged\)'"
            $p.query | Should -Match 'project value = v, label = v'
        }
        foreach ($item in $script:GraphQueries) { @($item.content.crossComponentResources) | Should -Be @('value::all') -Because $item.name }
    }

    It 'makes every All dropdown expand to no filtering and carry a time context' {
        foreach ($name in 'OsFilter', 'EnvironmentFilter', 'RoleFilter') {
            $p = $script:Parameters | Where-Object name -eq $name
            $p.type | Should -Be 2
            $p.multiSelect | Should -BeTrue
            $p.typeSettings.selectAllValue | Should -Be '' -Because $name
            @($p.typeSettings.additionalResourceOptions) | Should -Contain 'value::all'
            $p.timeContext.durationMs | Should -BeGreaterThan 0
        }
    }

    It 'writes the filter guard inline in every Resource Graph query that uses a filter' {
        $graphTexts = [ordered]@{
            'post-updates' = (Get-Query 'post-updates'); 'post-sql' = (Get-Query 'post-sql'); 'post-tags' = (Get-Query 'post-tags')
            'MachineScope' = ($script:Parameters | Where-Object name -eq 'MachineScope').query
        }
        foreach ($name in $graphTexts.Keys) {
            $q = $graphTexts[$name]
            foreach ($f in 'OsFilter', 'EnvironmentFilter', 'RoleFilter') {
                $list = [regex]::Escape("dynamic([{$f}])")
                $q | Should -Match "array_length\($list\) == 0 or set_has_element\($list, 'value::all'\) or set_has_element\($list, '\*'\)" -Because "$name $f"
            }
            $q | Should -Not -Match '(?m)^\s*let\s' -Because "${name}: Resource Graph rejects a let statement"
        }
    }

    It 'scopes every Log Analytics item through the one derived machine list, never through the filters directly' {
        foreach ($item in $script:LogQueries) {
            $item.content.query | Should -Match 'let Scope = dynamic\(\[\{MachineScope\}\]\);' -Because $item.name
            $item.content.query | Should -Not -Match '\{(OsFilter|EnvironmentFilter|RoleFilter)\}' -Because $item.name
        }
    }

    It 'expands to a valid filter list and a valid scope list for every form the portal can substitute' {
        $scope = ($script:Parameters | Where-Object name -eq 'MachineScope').query
        foreach ($case in @('', "'value::all'", "'*'", "'Windows','Linux'", "'Linux'")) {
            $expanded = $scope.Replace('{OsFilter}', $case).Replace('{EnvironmentFilter}', $case).Replace('{RoleFilter}', $case)
            $expanded | Should -Not -Match '\{[A-Za-z]'
            ([regex]::Matches($expanded, [regex]::Escape("dynamic([$case])"))).Count | Should -Be 12
        }
        $q = Get-Query 'kpi'
        $record = "'win-app-01|Connected|Windows|WS2016|app|full-monitor|1|Security updates pending|0|2|1|'"
        foreach ($case in @('', "'value::all'", $record, "$record,$record", "'~none'")) {
            $expanded = $q.Replace('{MachineScope}', $case).Replace('{AlertSummary}', "'3|Sev2|2026-11-02T01:00:00Z'").Replace('{TimeRange:startISO}', '2026-01-01T00:00:00.000Z').Replace('{TimeRange:endISO}', '2026-01-02T00:00:00.000Z')
            $expanded | Should -Not -Match '\{[A-Za-z]'
            $expanded | Should -Match ('let Scope = dynamic\(\[' + [regex]::Escape($case) + '\]\);')
        }
    }

    It 'gives every query item a specific no-data message' {
        foreach ($item in $script:Queries) {
            $item.content.noDataMessage | Should -Not -BeNullOrEmpty -Because $item.name
            $item.content.noDataMessage.Length | Should -BeGreaterThan 30 -Because "$($item.name) needs a reason, not a generic empty state"
            $item.content.noDataMessage | Should -Not -Match '^(No results|No data)\.?$' -Because $item.name
            $item.content.noDataMessageStyle | Should -BeIn @(3, 4, 5) -Because $item.name
        }
    }

    It 'orders the story: header, filters, tiles, trend charts, machines, then tabs with the data tab first' {
        $names = @($script:Book.items | ForEach-Object { $_.name })
        $names[0..6] | Should -Be @('header', 'filters', 'kpi-header', 'kpi', 'trend-header', 'beating', 'cpu-avg')
        $names[7..8] | Should -Be @('grid-header', 'grid')
        $tabs = $script:All | Where-Object { $_.type -eq 11 } | Select-Object -First 1
        @($tabs.content.links.subTarget) | Should -Be $script:TabNames
        $tabs.content.style | Should -Be 'tabs'
    }

    It 'shows each tab group only for its own tab value' {
        foreach ($tab in $script:TabNames) {
            $group = $script:Book.items | Where-Object name -eq "tab-$tab"
            $group.content.items.Count | Should -BeGreaterThan 0
            $group.conditionalVisibility.parameterName | Should -Be 'selectedTab'
            $group.conditionalVisibility.value | Should -Be $tab
        }
    }
}

Describe 'Estate Overview works through the ARM workspace query endpoint' {
    It 'uses no cross-service pattern in any Log Analytics item: the endpoint the portal uses rejects arg() and adx()' {
        foreach ($item in $script:LogQueries) {
            $item.content.query | Should -Not -Match '\b(arg|adx)\s*\(' -Because "$($item.name): the ARM workspace query endpoint answers 'The adx pattern cannot be used with the current authentication scheme'"
        }
        foreach ($parameter in @($script:Parameters | Where-Object { $_.query -and $_.queryType -eq 0 })) {
            $parameter.query | Should -Not -Match '\b(arg|adx)\s*\(' -Because $parameter.name
        }
        $script:Raw | Should -Not -Match '\barg\s*\('
    }

    It 'reads the Arc inventory once, through two hidden Resource Graph-driven parameters' {
        foreach ($name in 'MachineScope', 'AlertSummary') {
            $p = $script:Parameters | Where-Object name -eq $name
            $p.type | Should -Be 2
            $p.multiSelect | Should -BeTrue
            $p.isHiddenWhenLocked | Should -BeTrue
            $p.queryType | Should -Be 1
            $p.resourceType | Should -Be 'microsoft.resourcegraph/resources'
            @($p.crossComponentResources) | Should -Be @('value::all')
            $p.quote | Should -Be "'"
            $p.delimiter | Should -Be ','
            $p.typeSettings.PSObject.Properties.Name | Should -Not -Contain 'selectAllValue' -Because "${name}: All must expand to every record"
            @($p.typeSettings.additionalResourceOptions) | Should -Contain 'value::all'
        }
    }

    It 'builds one record per machine with twelve fields, clean separators and a sentinel when the filters match nothing' {
        $query = ($script:Parameters | Where-Object name -eq 'MachineScope').query
        $record = [regex]::Match($query, '(?s)extend Rec = strcat\((.+?)\)\r?\n\| summarize Recs').Groups[1].Value
        $record | Should -Not -BeNullOrEmpty
        ([regex]::Matches($record, "'\|'")).Count | Should -Be 11
        ([regex]::Matches($query, 'replace_regex')).Count | Should -BeGreaterOrEqual 4
        $query | Should -Match "dynamic\(\['~none'\]\)"
        $query | Should -Match "label = iff\(Recs startswith '~', '\(no machine matches the filters\)', tostring\(split\(Recs, '\|'\)\[0\]\)\)"
        $query | Should -Match "split\(tolower\(id\), '/patchassessmentresults/'\)" -Because 'the assessment key must be lower-cased before it is split'
    }

    It 'parses every field of that record in the Log Analytics prologue and nothing beyond it' {
        $q = Get-Query 'kpi'
        foreach ($index in 0..11) { $q | Should -Match "P\[$index\]" }
        $q | Should -Not -Match 'P\[12\]'
        $q | Should -Match "R !in \('value::all', '\*'\)"
    }

    It 'keeps the page populated if the scope arrives empty, and empty if the filters match nothing' {
        foreach ($name in 'kpi', 'grid', 'beating') {
            $q = Get-Query $name
            $q | Should -Match "let NoMatch = array_length\(Scope\) == 1 and tostring\(Scope\[0\]\) startswith '~'" -Because $name
            $q | Should -Match 'not\(HasInv\) and not\(NoMatch\)' -Because $name
        }
        (Get-Query 'kpi') | Should -Match 'inventory unavailable: heartbeat only'
        (Get-Query 'beating') | Should -Match 'where ArcCount > 0'
    }

    It 'takes the alert summary from the derived parameter and says so when it is unavailable' {
        (Get-Query 'kpi') | Should -Match "split\(tostring\(dynamic\(\[\{AlertSummary\}\]\)\[0\]\), '\|'\)"
        (Get-Query 'kpi') | Should -Match 'alert data unavailable'
        $p = $script:Parameters | Where-Object name -eq 'AlertSummary'
        $p.query | Should -Match '\{TimeRange:startISO\}'
        $p.query | Should -Match '\{TimeRange:endISO\}'
    }

    It 'reads the posture tables straight from Resource Graph, scoped by the same filters' {
        foreach ($name in 'post-updates', 'post-sql', 'post-tags', 'post-alerts') { (Get-Item $name).queryType | Should -Be 1 -Because $name }
    }
}

Describe 'Estate Overview tells the estate story with honest numbers' {
    It 'counts Arc machines once and reports telemetry separately, so a machine without an agent is present but not reporting' {
        $q = Get-Query 'kpi'
        $q | Should -Match 'InArcN = countif\(InArc\)'
        $q | Should -Match 'LastBeat > ago\(15m\)'
        $q | Should -Match 'NoAgent = NoBeat and InArc and isempty\(MonitorTier\)'
        $q | Should -Match 'without agent'
    }

    It 'measures last heartbeat over 14 days and never infers an agent from an extension' {
        $q = Get-Query 'grid'
        $q | Should -Match 'Heartbeat\s*\r?\n\| where TimeGenerated > ago\(14d\)'
        $q | Should -Not -Match 'microsoft\.hybridcompute/machines/extensions'
        $q | Should -Match "'No monitoring agent'"
        $q | Should -Match "'Silent'"
    }

    It 'reads real Update Manager data, never a connection-state estimate' {
        $sources = [ordered]@{ 'post-updates' = (Get-Query 'post-updates'); 'MachineScope' = ($script:Parameters | Where-Object name -eq 'MachineScope').query }
        foreach ($name in $sources.Keys) {
            $q = $sources[$name]
            $q | Should -Match 'patchassessmentresources' -Because $name
            $q | Should -Match 'microsoft\.hybridcompute/machines/patchassessmentresults' -Because $name
            $q | Should -Match "isempty\(AssessmentStatus\), 'Not assessed'" -Because $name
            $q | Should -Match "'Assessment failed'" -Because $name
            $q | Should -Not -Match 'HealthScore|EstimatedCritical|daysOffline' -Because $name
        }
        (Get-Query 'kpi') | Should -Match "Patched = countif\(PatchState == 'Fully patched'\)"
        (Get-Query 'grid') | Should -Match 'Updates = PatchState'
    }

    It 'zero-fills hosts reporting without depending on any heartbeat existing, and draws the Arc inventory as a baseline' {
        $q = Get-Query 'beating'
        $q | Should -Match 'range TimeGenerated from bin\(Start, Step\) to End step Step'
        $q | Should -Match 'coalesce\(Hosts, 0\)'
        $q | Should -Match "Series = 'Arc machines'"
        $q | Should -Not -Match 'make-series'
    }

    It 'leaves level-0 audit rows out of the Windows event items' {
        foreach ($name in 'ev-chart', 'ev-grid') {
            (Get-Query $name) | Should -Match 'EventLevel in \(1, 2, 3\)'
            (Get-Query $name) | Should -Not -Match 'EventLevel <= 2'
        }
    }

    It 'ranks syslog errors first and counts the agent severity name error as an error' {
        (Get-Query 'sys-grid') | Should -Match "'crit', 'err', 'error'"
        (Get-Query 'sys-grid') | Should -Match 'order by SeverityRank asc'
        (Get-Query 'sys-chart') | Should -Match "'crit', 'err', 'error'"
    }

    It 'does not chart blank-type change twin rows' {
        foreach ($name in 'chg-chart', 'chg-hosts') { (Get-Query $name) | Should -Match 'isnotempty\(ConfigChangeType\)' }
    }

    It 'takes CPU, memory and disk from the same canonical counters as the capacity workbook' {
        $q = Get-Query 'grid'
        $q | Should -Match 'ObjectName in \("Processor Information", "Processor"\) and CounterName == "% Processor Time" and InstanceName in \("_Total", "total"\)'
        $q | Should -Match '"% Committed Bytes In Use", "% Used Memory"'
        $q | Should -Match 'ObjectName in \("LogicalDisk", "Logical Disk"\) and CounterName == "% Free Space"'
        $q | Should -Match 'Namespace == "LogicalDisk" and Name == "FreeSpacePercentage"'
        $q | Should -Match 'InstanceName startswith "/snap/"'
        $q | Should -Match 'Priority = case\(ObjectName == "Processor Information", 0'
    }

    It 'leaves gaps as gaps: load series are null-filled, never zero-filled' {
        foreach ($name in 'cpu-avg', 'cpu-peak', 'mem', 'disk', 'detail-cpu', 'detail-mem', 'detail-disk') {
            (Get-Query $name) | Should -Match 'default = real\(null\)' -Because $name
        }
    }

    It 'drives the machine detail from one selected machine with a clear default' {
        $grid = Get-Item 'grid'
        $grid.exportFieldName | Should -Be 'Machine'
        $grid.exportParameterName | Should -Be 'SelectedMachine'
        $grid.exportDefaultValue | Should -Be '(none)'
        $detail = $script:Book.items | Where-Object name -eq 'tab-detail'
        foreach ($item in @($detail.content.items | Where-Object { $_.name -like 'detail-*' -and $_.name -ne 'detail-hint' })) {
            $item.conditionalVisibility.parameterName | Should -Be 'SelectedMachine' -Because $item.name
            $item.conditionalVisibility.value | Should -Be '(none)'
        }
        ($detail.content.items | Where-Object name -eq 'detail-hint').conditionalVisibility.comparison | Should -Be 'isEqualTo'
    }

    It 'keeps tile labels short and the subtitles bounded' {
        $labels = [regex]::Matches((Get-Query 'kpi'), "'l', '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        $labels.Count | Should -Be 8
        foreach ($label in $labels) { $label.Length | Should -BeLessOrEqual 20 -Because $label }
    }

    It 'reports parked and silent states in words instead of looking broken' {
        (Get-Query 'kpi') | Should -Match 'none in 15 min: parked or silent'
        (Get-Query 'grid') | Should -Match 'No heartbeat in 15 minutes: parked, or the agent is stopped'
        (Get-Query 'grid') | Should -Match 'No Azure Monitor Agent: listed from Arc inventory only'
    }
}

Describe 'Estate Overview colours mean what they say' {
    BeforeAll {
        function Get-Formatter($Name, $Column) { ((Get-Item $Name).gridSettings.formatters | Where-Object columnMatch -eq $Column) }
    }

    It 'paints low load green and high load red, and low free space red' {
        foreach ($column in 'CpuMean', 'CpuPeak', 'MemP95') { (Get-Formatter 'grid' $column).formatOptions.palette | Should -Be 'greenRed' -Because $column }
        (Get-Formatter 'grid' 'FreePct').formatOptions.palette | Should -Be 'redGreen'
    }

    It 'keeps percentage columns numeric so bars can scale' {
        $q = Get-Query 'grid'
        foreach ($column in 'CpuMean', 'CpuPeak', 'MemP95', 'FreePct') { $q | Should -Match "$column = round\(" }
    }

    It 'maps telemetry and update states to colours that match their meaning' {
        $telemetry = @{}
        foreach ($rule in (Get-Formatter 'grid' 'Telemetry').formatOptions.thresholdsGrid) { if ($rule.thresholdValue) { $telemetry[$rule.thresholdValue] = $rule.representation } }
        $telemetry['Reporting'] | Should -Be 'green'
        $telemetry['Silent'] | Should -Be 'orange'
        $telemetry['No telemetry'] | Should -Be 'redBright'
        $telemetry['No monitoring agent'] | Should -Be 'gray'
        $patch = @{}
        foreach ($rule in (Get-Formatter 'grid' 'Updates').formatOptions.thresholdsGrid) { if ($rule.thresholdValue) { $patch[$rule.thresholdValue] = $rule.representation } }
        $patch['Fully patched'] | Should -Be 'green'
        $patch['Critical updates pending'] | Should -Be 'redBright'
        $patch['Security updates pending'] | Should -Be 'orange'
        $patch['Not assessed'] | Should -Be 'gray'
    }

    It 'never uses a numeric bar on a string column' {
        foreach ($item in @($script:Queries | Where-Object { $_.content.gridSettings })) {
            foreach ($formatter in @($item.content.gridSettings.formatters | Where-Object formatter -eq 8)) {
                $formatter.columnMatch | Should -Not -Match '^(Machine|Updates|Telemetry|State|Level|Severity|Os|Tier|Role)$' -Because "$($item.name) $($formatter.columnMatch)"
            }
        }
    }
}

Describe 'The presenter template names only what the Estate Overview shows' {
    It 'finds every bold name in scene 1 as a tile, item title, tab or filter in the workbook' {
        $template = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'docs/runsheet.md') -Raw
        $scene = [regex]::Match($template, '(?s)## 1\. .*?(?=\r?\n## 2\. )').Value
        $scene | Should -Not -BeNullOrEmpty
        $vocabulary = @($script:Queries | ForEach-Object { $_.content.title })
        $vocabulary += @(($script:All | Where-Object { $_.type -eq 11 }) | ForEach-Object { $_.content.links.linkLabel })
        $vocabulary += [regex]::Matches((Get-Query 'kpi'), "'l', '([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        $names = [regex]::Matches($scene, '\*\*([^*]+)\*\*') | ForEach-Object { ($_.Groups[1].Value -replace '\s+', ' ').Trim() } | Where-Object { $_ -notmatch '^Say:$' }
        $names.Count | Should -BeGreaterThan 8
        foreach ($name in $names) {
            @($vocabulary | Where-Object { $_ -like "*$name*" }).Count | Should -BeGreaterThan 0 -Because "scene 1 names '$name'"
        }
    }

    It 'no longer names the retired Estate Overview tiles' {
        $template = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'docs/runsheet.md') -Raw
        $template | Should -Not -Match 'Estate connectivity \(last 15m\)|Hosts beating over time|Per-host CPU utilisation|Linux syslog activity \(24h\)|Tagging hygiene'
    }
}

Describe 'Estate Overview queries executed read-only against the live workspace through both query endpoints' -Skip:([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    BeforeAll {
        $ErrorActionPreference = 'Stop'
        $repo = Split-Path $PSScriptRoot
        Import-Module (Join-Path $repo 'scripts/lib/Common.psm1') -Force
        if ($WorkspaceResourceId -notmatch ('^/subscriptions/' + [regex]::Escape($SubscriptionId.ToString()) + '/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.OperationalInsights/workspaces/[A-Za-z0-9._()-]+$')) {
            throw 'Test workspace must be an exact ID in the explicitly confirmed subscription.'
        }
        Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId
        $workspace = Invoke-DemoAz -Arguments @('resource', 'show', '--ids', $WorkspaceResourceId, '-o', 'json') | ConvertFrom-Json
        if ($workspace.id -ne $WorkspaceResourceId -or -not $workspace.properties.customerId) { throw 'Test workspace identity/customerId unknown.' }
        $lawToken = Get-LawQueryToken
        $lawHeaders = @{ Authorization = ('Bearer ' + $lawToken) }
        $uri = "https://api.loganalytics.io/v1/workspaces/$($workspace.properties.customerId)/query"
        $iso = { param([datetime]$d) $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) }
        $end = [datetime]::UtcNow
        $armToken = Get-MgmtToken
        $armUri = "https://management.azure.com$WorkspaceResourceId/query?api-version=2017-10-01"
        $graphUri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01'
        $cases = [ordered]@{
            empty = @{ OsFilter = ''; EnvironmentFilter = ''; RoleFilter = '' }
            marker = @{ OsFilter = "'value::all'"; EnvironmentFilter = "'value::all'"; RoleFilter = "'value::all'" }
            star = @{ OsFilter = "'*'"; EnvironmentFilter = "'*'"; RoleFilter = "'*'" }
            linux = @{ OsFilter = "'Linux'"; EnvironmentFilter = ''; RoleFilter = '' }
            nomatch = @{ OsFilter = "'Linux'"; EnvironmentFilter = ''; RoleFilter = "'sql'" }
            scopeEmpty = @{ OsFilter = ''; EnvironmentFilter = ''; RoleFilter = ''; MachineScope = '' }
            scopeMarker = @{ OsFilter = ''; EnvironmentFilter = ''; RoleFilter = ''; MachineScope = "'value::all'" }
        }
        function Expand([string]$Query, [hashtable]$Values) {
            $text = $Query.Replace('{TimeRange:startISO}', (& $iso $end.AddHours(-24))).Replace('{TimeRange:endISO}', (& $iso $end)).Replace('{SelectedMachine}', 'none-selected')
            foreach ($key in $Values.Keys) { $text = $text.Replace('{' + $key + '}', $Values[$key]) }
            $text
        }
        function Invoke-Graph([string]$Query) {
            $body = @{ subscriptions = @($SubscriptionId.ToString()); query = $Query; options = @{ resultFormat = 'objectArray' } } | ConvertTo-Json -Depth 5
            @((Invoke-RestMethod -Method POST -Uri $graphUri -Headers @{ Authorization = "Bearer $armToken" } -ContentType 'application/json' -Body $body -TimeoutSec 120).data)
        }
        # The hidden parameters resolve as the portal resolves All: every option value, quoted and comma separated.
        foreach ($name in @($cases.Keys)) {
            $values = $cases[$name]
            foreach ($derived in 'MachineScope', 'AlertSummary') {
                if ($values.ContainsKey($derived)) { continue }
                $parameter = $script:Parameters | Where-Object name -eq $derived
                $options = @(Invoke-Graph (Expand $parameter.query $values) | ForEach-Object { [string]$_.value })
                $values[$derived] = (@($options | ForEach-Object { "'$_'" }) -join ',')
            }
        }
        $items = @($script:LogQueries | Where-Object { -not $_.conditionalVisibility })
        $requests = foreach ($case in $cases.Keys) {
            foreach ($item in $items) { [pscustomobject]@{ Key = "data/$case/$($item.name)"; Body = (@{ query = (Expand $item.content.query $cases[$case]) } | ConvertTo-Json -Depth 5) } }
        }
        $armRequests = foreach ($case in $cases.Keys) {
            foreach ($item in $items) { [pscustomobject]@{ Key = "arm/$case/$($item.name)"; Body = (@{ query = (Expand $item.content.query $cases[$case]) } | ConvertTo-Json -Depth 5) } }
        }
        $responses = @($requests | ForEach-Object -ThrottleLimit 4 -Parallel {
            $request = $_
            try {
                $reply = Invoke-RestMethod -Method POST -Uri $using:uri -Headers $using:lawHeaders -ContentType 'application/json' -Body $_.Body -TimeoutSec 180
                [pscustomobject]@{ Key = $_.Key; Reply = $reply; Error = '' }
            } catch {
                [pscustomobject]@{ Key = $request.Key; Reply = $null; Error = $(if ($_.ErrorDetails.Message) { [string]$_.ErrorDetails.Message } else { $_.Exception.Message }) }
            }
        })
        $armResponses = @($armRequests | ForEach-Object -ThrottleLimit 4 -Parallel {
            $request = $_
            try {
                $reply = Invoke-RestMethod -Method POST -Uri $using:armUri -Headers @{ Authorization = "Bearer $using:armToken" } -ContentType 'application/json' -Body $_.Body -TimeoutSec 180
                [pscustomobject]@{ Key = $_.Key; Reply = $reply; Error = '' }
            } catch {
                [pscustomobject]@{ Key = $request.Key; Reply = $null; Error = $(if ($_.ErrorDetails.Message) { [string]$_.ErrorDetails.Message } else { $_.Exception.Message }) }
            }
        })
        $live = @{}
        foreach ($response in @($responses) + @($armResponses)) {
            # The data plane answers tables/columns/name; the ARM endpoint answers the legacy Tables/Columns/ColumnName shape.
            $reply = $response.Reply
            $tables = @(if ($reply) { if ($reply.PSObject.Properties['tables']) { $reply.tables } elseif ($reply.PSObject.Properties['Tables']) { $reply.Tables } })
            $names = @()
            $records = @()
            if ($tables.Count) {
                $table = $tables[0]
                $names = @(if ($table.PSObject.Properties['columns']) { $table.columns | ForEach-Object { $_.name } } else { $table.Columns | ForEach-Object { $_.ColumnName } })
                $rowProperty = if ($table.PSObject.Properties['rows']) { 'rows' } else { 'Rows' }
                $records = @(foreach ($row in $table.$rowProperty) {
                    $record = [ordered]@{}
                    for ($i = 0; $i -lt $names.Count; $i++) { $record[[string]$names[$i]] = $row[$i] }
                    [pscustomobject]$record
                })
            }
            $live[$response.Key] = [pscustomobject]@{ Error = $response.Error; Columns = $names; Rows = $records }
        }
    }

    It 'runs every default-view Log Analytics item through the ARM workspace query endpoint and the data plane without an error' {
        foreach ($key in $live.Keys) { $live[$key].Error | Should -BeNullOrEmpty -Because $key }
    }

    It 'returns data or has a specific no-data reason for every item' {
        foreach ($key in $live.Keys) {
            $name = ($key -split '/')[2]
            if ($live[$key].Rows.Count -eq 0) { (Get-Item $name).noDataMessage | Should -Not -BeNullOrEmpty -Because $key }
        }
    }

    It 'counts the same Arc machines under every form of All and through both endpoints' {
        foreach ($endpoint in 'arm', 'data') {
            $counts = foreach ($case in 'empty', 'marker', 'star') { ($live["$endpoint/$case/kpi"].Rows | Where-Object Label -like '*Arc machines*').Value }
            @($counts | Select-Object -Unique).Count | Should -Be 1 -Because $endpoint
            $grid = foreach ($case in 'empty', 'marker', 'star') { $live["$endpoint/$case/grid"].Rows.Count }
            @($grid | Select-Object -Unique).Count | Should -Be 1 -Because $endpoint
        }
        ($live['arm/empty/kpi'].Rows | Where-Object Label -like '*Arc machines*').Value | Should -Be ($live['data/empty/kpi'].Rows | Where-Object Label -like '*Arc machines*').Value
    }

    It 'follows a real selection and shows nothing, rather than everything, when the filters match no machine' {
        $live['arm/linux/grid'].Rows.Count | Should -BeLessOrEqual $live['arm/empty/grid'].Rows.Count
        $live['arm/linux/grid'].Rows.Count | Should -BeGreaterThan 0
        foreach ($row in $live['arm/linux/grid'].Rows) { $row.Os | Should -Be 'Linux' }
        $live['arm/nomatch/grid'].Rows.Count | Should -Be 0
        ($live['arm/nomatch/kpi'].Rows | Where-Object Label -like '*Arc machines*').Value | Should -Be 0
    }

    It 'keeps the page populated, and says why, when the scope arrives empty or as the literal All marker' {
        foreach ($case in 'scopeEmpty', 'scopeMarker') {
            $live["arm/$case/grid"].Rows.Count | Should -BeGreaterThan 0 -Because $case
            ($live["arm/$case/kpi"].Rows | Where-Object Label -like '*Arc machines*').Note | Should -Match 'inventory unavailable' -Because $case
        }
    }

    It 'returns every column that a formatter, label, tile or chart refers to' {
        foreach ($key in $live.Keys) {
            $name = ($key -split '/')[2]
            $content = Get-Item $name
            $columns = $live[$key].Columns
            if (-not $live[$key].Rows.Count) { continue }
            if ($content.gridSettings) {
                foreach ($formatter in $content.gridSettings.formatters) {
                    @($formatter.columnMatch -split '\|' | Where-Object { $_ -in $columns }).Count | Should -BeGreaterThan 0 -Because "$key formatter $($formatter.columnMatch)"
                }
                foreach ($label in @($content.gridSettings.labelSettings)) { if ($label) { $label.columnId | Should -BeIn $columns -Because "$key label" } }
            }
            if ($content.tileSettings) {
                foreach ($part in 'titleContent', 'leftContent', 'secondaryContent') { $content.tileSettings.$part.columnMatch | Should -BeIn $columns -Because "$key $part" }
            }
            if ($content.exportFieldName) { $content.exportFieldName | Should -BeIn $columns -Because $key }
        }
    }

    It 'keeps tile labels and notes short enough for the default tile width' {
        $tiles = $live['arm/empty/kpi'].Rows
        $tiles.Count | Should -Be 8
        foreach ($tile in $tiles) {
            $tile.Label.Length | Should -BeLessOrEqual 20 -Because $tile.Label
            $tile.Note.Length | Should -BeLessOrEqual 44 -Because $tile.Note
        }
    }
}
