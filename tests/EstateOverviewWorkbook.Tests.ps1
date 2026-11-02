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
        $known = @('TimeRange:startISO', 'TimeRange:endISO', 'OsFilter', 'EnvironmentFilter', 'RoleFilter', 'SelectedMachine')
        foreach ($item in $script:Queries) {
            foreach ($match in [regex]::Matches($item.content.query, '\{([A-Za-z][A-Za-z0-9]*(?::[A-Za-z]+)?)\}')) {
                $match.Groups[1].Value | Should -BeIn $known -Because "$($item.name) uses {$($match.Groups[1].Value)}"
            }
        }
    }

    It 'defines no Log Analytics time context, so the 14-day heartbeat lookback is not cut to the time range' {
        foreach ($item in $script:LogQueries) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'timeContextFromParameter' -Because $item.name }
    }
}

Describe 'Estate Overview opens with data and zero clicks' {
    It 'gives every parameter a working default' {
        $script:Parameters.Count | Should -Be 4
        ($script:Parameters | Where-Object name -eq 'TimeRange').value.durationMs | Should -Be 86400000
        foreach ($name in 'OsFilter', 'EnvironmentFilter', 'RoleFilter') {
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

    It 'accepts an empty list, the literal All marker and an asterisk for every filter in every Log Analytics query' {
        foreach ($item in $script:LogQueries) {
            $q = $item.content.query
            foreach ($f in 'OsF', 'EnvF', 'RoleF') {
                $q | Should -Match "array_length\($f\) == 0 or set_has_element\($f, 'value::all'\) or set_has_element\($f, '\*'\)" -Because "$($item.name) $f"
            }
            $q | Should -Match '\(OsAll or Os in \(OsF\)\) and \(EnvAll or Env in \(EnvF\)\) and \(RoleAll or Role in \(RoleF\)\)' -Because $item.name
        }
    }

    It 'expands to a valid filter list for every form the portal can substitute' {
        $q = Get-Query 'kpi'
        foreach ($case in @('', "'value::all'", "'*'", "'Windows','Linux'", "'Linux'")) {
            $expanded = $q.Replace('{OsFilter}', $case).Replace('{EnvironmentFilter}', $case).Replace('{RoleFilter}', $case).Replace('{TimeRange:startISO}', '2026-01-01T00:00:00.000Z').Replace('{TimeRange:endISO}', '2026-01-02T00:00:00.000Z')
            $expanded | Should -Not -Match '\{[A-Za-z]'
            $expanded | Should -Match ('let OsF = dynamic\(\[' + [regex]::Escape($case) + '\]\);')
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
        foreach ($name in 'kpi', 'grid', 'post-updates') {
            $q = Get-Query $name
            $q | Should -Match 'patchassessmentresources'
            $q | Should -Match 'microsoft\.hybridcompute/machines/patchassessmentresults'
            $q | Should -Match "isempty\(AssessmentStatus\), 'Not assessed'"
            $q | Should -Match "'Assessment failed'"
            $q | Should -Not -Match 'HealthScore|EstimatedCritical|daysOffline'
        }
        (Get-Query 'kpi') | Should -Match "Patched = countif\(PatchState == 'Fully patched'\)"
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

Describe 'Estate Overview queries executed read-only against the live workspace' -Skip:([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
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
        $token = Get-LawQueryToken
        $uri = "https://api.loganalytics.io/v1/workspaces/$($workspace.properties.customerId)/query"
        $iso = { param([datetime]$d) $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture) }
        $end = [datetime]::UtcNow
        $expansions = [ordered]@{
            empty = @{ OsFilter = ''; EnvironmentFilter = ''; RoleFilter = '' }
            marker = @{ OsFilter = "'value::all'"; EnvironmentFilter = "'value::all'"; RoleFilter = "'value::all'" }
            star = @{ OsFilter = "'*'"; EnvironmentFilter = "'*'"; RoleFilter = "'*'" }
        }
        function Expand([string]$Query, [hashtable]$Values) {
            $text = $Query.Replace('{TimeRange:startISO}', (& $iso $end.AddHours(-24))).Replace('{TimeRange:endISO}', (& $iso $end)).Replace('{SelectedMachine}', 'none-selected')
            foreach ($key in $Values.Keys) { $text = $text.Replace('{' + $key + '}', $Values[$key]) }
            $text
        }
        $items = @($script:LogQueries | Where-Object { -not $_.conditionalVisibility })
        $requests = foreach ($case in $expansions.Keys) {
            foreach ($item in $items) { [pscustomobject]@{ Key = "$case/$($item.name)"; Body = (@{ query = (Expand $item.content.query $expansions[$case]) } | ConvertTo-Json -Depth 5) } }
        }
        $responses = @($requests | ForEach-Object -ThrottleLimit 4 -Parallel {
            try {
                $reply = Invoke-RestMethod -Method POST -Uri $using:uri -Headers @{ Authorization = "******" } -ContentType 'application/json' -Body $_.Body -TimeoutSec 180
                [pscustomobject]@{ Key = $_.Key; Reply = $reply; Error = '' }
            } catch {
                [pscustomobject]@{ Key = $_.Key; Reply = $null; Error = [string]$_.ErrorDetails.Message }
            }
        })
        $live = @{}
        foreach ($response in $responses) {
            $table = if ($response.Reply -and @($response.Reply.tables).Count) { $response.Reply.tables[0] } else { $null }
            $live[$response.Key] = [pscustomobject]@{
                Error = $response.Error
                Columns = @(if ($table) { $table.columns.name })
                Rows = @(if ($table) { foreach ($row in $table.rows) { $record = [ordered]@{}; for ($i = 0; $i -lt $table.columns.Count; $i++) { $record[$table.columns[$i].name] = $row[$i] }; [pscustomobject]$record } })
            }
        }
    }

    It 'runs every default-view Log Analytics item under every expansion of All without an error' {
        foreach ($key in $live.Keys) { $live[$key].Error | Should -BeNullOrEmpty -Because $key }
    }

    It 'returns data or has a specific no-data reason for every item' {
        foreach ($key in $live.Keys) {
            $name = ($key -split '/')[1]
            if ($live[$key].Rows.Count -eq 0) { (Get-Item $name).noDataMessage | Should -Not -BeNullOrEmpty -Because $key }
        }
    }

    It 'counts the same Arc machines under every form of All' {
        $counts = foreach ($case in $expansions.Keys) { ($live["$case/kpi"].Rows | Where-Object Label -like '*Arc machines*').Value }
        @($counts | Select-Object -Unique).Count | Should -Be 1
        $grid = foreach ($case in $expansions.Keys) { $live["$case/grid"].Rows.Count }
        @($grid | Select-Object -Unique).Count | Should -Be 1
    }

    It 'returns every column that a formatter, label, tile or chart refers to' {
        foreach ($key in $live.Keys) {
            $name = ($key -split '/')[1]
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
        $tiles = $live['empty/kpi'].Rows
        $tiles.Count | Should -Be 8
        foreach ($tile in $tiles) {
            $tile.Label.Length | Should -BeLessOrEqual 20 -Because $tile.Label
            $tile.Note.Length | Should -BeLessOrEqual 44 -Because $tile.Note
        }
    }
}
