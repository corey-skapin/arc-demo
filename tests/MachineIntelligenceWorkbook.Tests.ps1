BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $path = Join-Path $repo 'workbooks\nseilaz\ArcMachineIntelligenceCenter.json'
    $raw = Get-Content -LiteralPath $path -Raw
    $book = $raw | ConvertFrom-Json -Depth 100

    function Get-AllItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.type -eq 12 -and $item.content.items) { Get-AllItem $item.content.items }
        }
    }
    $items = @(Get-AllItem $book.items)
    $queries = @($items | Where-Object { $_.type -eq 3 })
    $arg = @($queries | Where-Object { $_.content.queryType -eq 1 })
    $la = @($queries | Where-Object { $_.content.queryType -eq 0 })
    $parameters = @($items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })

    # Column names of a query's last top-level "| project" clause (null when the query does not end in a project).
    function Get-ProjectedColumn([string]$Query) {
        $index = $Query.LastIndexOf('| project ')
        if ($index -lt 0) { return $null }
        $clause = $Query.Substring($index + 10)
        if ($clause -match '\n\|') { return $null }
        $depth = 0; $current = ''; $parts = @()
        foreach ($ch in $clause.ToCharArray()) {
            if ($ch -in '(', '[') { $depth++ } elseif ($ch -in ')', ']') { $depth-- }
            if ($ch -eq ',' -and $depth -eq 0) { $parts += $current; $current = '' } else { $current += $ch }
        }
        $parts += $current
        @($parts | ForEach-Object { $name = ($_ -split '=')[0].Trim(); if ($name -match '^\[''(.+)''\]$') { $Matches[1] } else { $name } })
    }
}

Describe 'Machine Intelligence Center opens populated, with no clicks and no waiting' {
    It 'is a Notebook/1.0 workbook that keeps the upstream attribution' {
        $book.version | Should -Be 'Notebook/1.0'
        $raw | Should -Match 'Nic Seilaz'
        $raw | Should -Match 'github\.com/nseilaz/AzureArc_Workbooks'
        $raw | Should -Match 'MIT'
    }

    It 'picks the machine from a Resource Graph query that always marks exactly one row selected, so no tile waits for a click' {
        $machine = $parameters | Where-Object name -eq 'Machine'
        $machine.type | Should -Be 2
        $machine.isRequired | Should -BeTrue
        $machine.queryType | Should -Be 1
        $machine.resourceType | Should -Be 'microsoft.resourcegraph/resources'
        $machine.query | Should -Match 'selected = IsBest == true, group = Group'
        $machine.query | Should -Match 'project value = name, label = .+, selected = IsBest == true, group = Group'
        $machine.query | Should -Not -Match '(?m)^\s*let '
        $machine.PSObject.Properties.Name | Should -Not -Contain 'value'
    }

    It 'lists every Arc machine, opens on the Windows SQL host with the Azure Monitor Agent and labels machines without it' {
        $machine = $parameters | Where-Object name -eq 'Machine'
        $machine.query | Should -Not -Match 'arg\('
        $machine.query | Should -Match "type =~ 'microsoft\.hybridcompute/machines'"
        $machine.query | Should -Match 'AzureMonitorWindowsAgent'
        $machine.query | Should -Match 'Windows with Azure Monitor Agent'
        $machine.query | Should -Match 'no Azure Monitor Agent'
        $machine.query | Should -Match "SortKey = strcat\(tostring\(GroupOrder\), iff\(SqlHost == true, '0', '1'\), tolower\(name\)\)"
        $machine.query | Should -Match 'summarize BestKey = min\(SortKey\)'
    }

    It 'has a default time range' {
        $time = $parameters | Where-Object name -eq 'TimeRange'
        $time.type | Should -Be 4
        $time.value.durationMs | Should -BeGreaterThan 0
    }

    It 'has no workspace picker and no parameter that can be left empty' {
        @($parameters | Where-Object type -eq 5).Count | Should -Be 0
        $raw | Should -Not -Match 'LogAnalyticsWorkspace'
        $raw | Should -Not -Match 'SelectedMachine'
        foreach ($parameter in $parameters) { $parameter.isRequired | Should -BeTrue -Because $parameter.name }
    }

    It 'ships no workspace scope of its own: Phase 11 pins every Log Analytics tile and hidden switch to the deployment workspace at publish' {
        foreach ($item in $la) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $item.name }
        foreach ($parameter in @($parameters | Where-Object { $_.queryType -eq 0 })) { $parameter.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $parameter.name }
        @(($parameters | Where-Object name -eq 'Machine').crossComponentResources) | Should -Be @('value::all')
        $book.PSObject.Properties.Name | Should -Not -Contain 'fallbackResourceIds'
        $raw | Should -Not -Match '/subscriptions/'
        $raw | Should -Not -Match '(?i)law-[a-z0-9-]+'
        $raw | Should -Not -Match '(?i)onmicrosoft\.com'
    }

    It 'matches the machine by name whether the value is a name or a resource ID' {
        foreach ($item in $queries) { $item.content.query | Should -Match "split\('\{Machine\}', '/'\)\[-1\]" -Because $item.name }
    }

    It 'keeps Resource Graph queries free of let statements, which Resource Graph rejects' {
        foreach ($item in $arg) { $item.content.query | Should -Not -Match '(?m)^\s*let ' -Because $item.name }
    }

    It 'reads Windows and Linux from the same Perf counters, not Windows-only InsightsMetrics for memory' {
        $memory = ($la | Where-Object name -eq 'perf-mem').content.query
        $memory | Should -Match '% Committed Bytes In Use'
        $memory | Should -Match '% Used Memory'
        $available = ($la | Where-Object name -eq 'perf-avail').content.query
        $available | Should -Match 'Available MBytes Memory'
        ($la | Where-Object name -eq 'perf-disk').content.query | Should -Match "'Logical Disk', 'LogicalDisk'"
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-avail') { ($la | Where-Object name -eq $name).content.query | Should -Not -Match 'InsightsMetrics' -Because $name }
    }
}

Describe 'Machine Intelligence Center never shows a silent blank' {
    It 'gives every tile a specific message for an empty result' {
        foreach ($item in $queries) {
            $message = [string]$item.content.noDataMessage
            $message.Length | Should -BeGreaterThan 60 -Because $item.name
            $message | Should -Not -Match '^(No results|No data)\.?$' -Because $item.name
        }
    }

    It 'explains the missing Azure Monitor Agent on every telemetry tile' {
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-avail', 'perf-disk', 'perf-dist', 'perf-volumes', 'events-heartbeat', 'events-sources') {
            ($la | Where-Object name -eq $name).content.noDataMessage | Should -Match 'no Azure Monitor Agent' -Because $name
        }
    }

    It 'follows the time range on every Log Analytics tile and never on Resource Graph tiles' {
        foreach ($item in $la) { $item.content.timeContextFromParameter | Should -Be 'TimeRange' -Because $item.name }
        foreach ($item in $arg) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'timeContextFromParameter' -Because $item.name }
    }

    It 'always returns the headline tiles, even for a machine with no telemetry' {
        $live = ($la | Where-Object name -eq 'glance-live').content.query
        foreach ($text in 'No heartbeat', 'No data') { $live | Should -Match $text }
        $live | Should -Match 'print Dummy = 1'
    }

    It 'wires every tab link to exactly one group' {
        $links = @($book.items | Where-Object { $_.type -eq 11 } | ForEach-Object { $_.content.links })
        $links.Count | Should -BeGreaterThan 3
        foreach ($link in $links) {
            $groups = @($book.items | Where-Object { $_.type -eq 12 -and $_.conditionalVisibility.parameterName -eq 'selectedTab' -and $_.conditionalVisibility.value -eq $link.subTarget })
            $groups.Count | Should -Be 1 -Because $link.linkLabel
        }
    }
}

Describe 'Machine Intelligence Center tiles stay readable and mean what they say' {
    It 'keeps tile labels at 18 characters and every other tile text at 30 characters, so nothing is cut at the default tile width' {
        foreach ($item in @($queries | Where-Object { $_.content.visualization -eq 'tiles' })) {
            foreach ($match in [regex]::Matches($item.content.query, "'Label', '([^']*)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because "$($item.name): $($match.Groups[1].Value)" }
            foreach ($line in ($item.content.query -split "`n" | Where-Object { $_ -match "pack\('Label'" })) {
                foreach ($literal in [regex]::Matches($line, "'[^']*'")) { ($literal.Value.Length - 2) | Should -BeLessOrEqual 30 -Because "$($item.name): $($literal.Value)" }
            }
        }
    }

    It 'points every tile and grid formatter at a column the query actually returns' {
        foreach ($item in $queries) {
            $columns = Get-ProjectedColumn $item.content.query
            if (-not $columns) { continue }
            $content = $item.content
            if ($content.tileSettings) {
                foreach ($key in 'titleContent', 'leftContent', 'secondaryContent') { $columns | Should -Contain $content.tileSettings.$key.columnMatch -Because "$($item.name) $key" }
            }
            if ($content.gridSettings) {
                foreach ($formatter in $content.gridSettings.formatters) {
                    foreach ($name in ([string]$formatter.columnMatch -split '\|')) { $columns | Should -Contain $name -Because "$($item.name) formatter $name" }
                }
                foreach ($label in $content.gridSettings.labelSettings) { $columns | Should -Contain $label.columnId -Because "$($item.name) label $($label.columnId)" }
            }
        }
    }

    It 'never paints a low free-space number green or a high utilisation number green' {
        foreach ($item in $queries) {
            foreach ($formatter in @($item.content.gridSettings.formatters | Where-Object { $_.formatter -in 8, 12 })) {
                $palette = [string]$formatter.formatOptions.palette
                if ($formatter.columnMatch -match 'Free|Lowest') { $palette | Should -Be 'redGreen' -Because "$($item.name) $($formatter.columnMatch)" }
                elseif ($formatter.columnMatch -match 'Errors|Warnings|Cpu|Mem|Mean|Peak') { $palette | Should -Not -Be 'redGreen' -Because "$($item.name) $($formatter.columnMatch)" }
            }
        }
    }

    It 'gives every chart a fixed zero baseline and a percentage axis capped at 100' {
        foreach ($name in 'perf-cpu-peak', 'perf-mem', 'perf-disk', 'events-heartbeat') {
            $chart = ($la | Where-Object name -eq $name).content.chartSettings.ySettings
            $chart.min | Should -Be 0 -Because $name
            $chart.max | Should -Be 100 -Because $name
        }
        foreach ($name in 'perf-cpu-avg', 'perf-avail') { ($la | Where-Object name -eq $name).content.chartSettings.ySettings.min | Should -Be 0 -Because $name }
    }
}

Describe 'Machine Intelligence Center renders cleanly in the portal' {
    It 'is titled Center, matching the workbook name' {
        $title = ($items | Where-Object { $_.name -eq 'title' }).content.json
        $title | Should -Match '^# Arc Machine Intelligence Center'
        $raw | Should -Not -Match 'Centre'
    }

    It 'draws every time series as columns with no legend totals, so a parked or silent interval is a break, never a zero or a straight line' {
        $charts = @($la | Where-Object { $_.content.visualization -in 'timechart', 'linechart', 'barchart', 'areachart' })
        $charts.Count | Should -BeGreaterThan 5
        foreach ($item in $charts) {
            $item.content.visualization | Should -Be 'barchart' -Because $item.name
            $item.content.chartSettings.showMetrics | Should -BeFalse -Because "$($item.name) must not show (Sum) totals"
        }
        $raw | Should -Not -Match '"visualization":\s*"timechart"'
    }

    It 'plots a non-additive measure (a percentage, a minimum, a peak) as one series per chart so columns can never be misread as a stack' {
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-avail', 'perf-disk', 'events-heartbeat') {
            $query = ($la | Where-Object name -eq $name).content.query
            $columns = Get-ProjectedColumn $query
            @($columns).Count | Should -Be 2 -Because "$name returns TimeGenerated plus exactly one measure"
            $query | Should -Not -Match 'by Volume' -Because $name
        }
    }

    It 'keeps missing intervals null in the measure series instead of filling them with zero' {
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-avail', 'perf-disk') {
            ($la | Where-Object name -eq $name).content.query | Should -Match 'default = real\(null\)' -Because $name
        }
    }

    It 'shows a legend only where a chart has several series, and puts it below the chart' {
        foreach ($name in 'software-chart', 'events-chart', 'sql-workload') {
            $chart = ($la | Where-Object name -eq $name).content.chartSettings
            $chart.showLegend | Should -BeTrue -Because $name
            $chart.simpleLegendSettings.position | Should -Be 'bottom' -Because $name
        }
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-avail', 'perf-disk', 'events-heartbeat') {
            ($la | Where-Object name -eq $name).content.chartSettings.showLegend | Should -BeFalse -Because $name
        }
    }

    It 'leaves no table at the Small size, which reserves a fixed block of blank space under a short table, and bounds every table' {
        $tables = @($queries | Where-Object { $_.content.visualization -eq 'table' })
        $tables.Count | Should -BeGreaterThan 8
        foreach ($item in $tables) {
            $item.content.size | Should -Be 3 -Because $item.name
            $bounded = ($item.content.query -match '\| take \d+') -or ($item.content.gridSettings.rowLimit -gt 0) -or ($item.content.query -match 'make-series|summarize')
            $bounded | Should -BeTrue -Because "$($item.name) must be bounded when it is shown at the Full size"
        }
    }

    It 'formats every date and time column as a readable local date instead of a raw ISO string' {
        foreach ($item in $queries) {
            foreach ($formatter in @($item.content.gridSettings.formatters | Where-Object { $_.columnMatch -match '^(TimeGenerated|Since|LastSample|Last)$' })) {
                $formatter.formatter | Should -Be 6 -Because "$($item.name) $($formatter.columnMatch)"
                $formatter.dateFormat.formatName | Should -Be 'shortDateTimeNoMsPattern' -Because "$($item.name) $($formatter.columnMatch)"
                $formatter.dateFormat.showUtcTime | Should -BeNullOrEmpty -Because "$($item.name): null means local time"
            }
        }
        foreach ($pair in @(@('perf-volumes', 'LastSample'), @('security-open', 'Since'), @('software-table', 'TimeGenerated'), @('events-sources', 'Last'))) {
            $item = $queries | Where-Object name -eq $pair[0]
            @($item.content.gridSettings.formatters | Where-Object { $_.columnMatch -eq $pair[1] -and $_.formatter -eq 6 }).Count | Should -Be 1 -Because "$($pair[0]) $($pair[1])"
        }
    }

    It 'sizes every grid column in proportional fr units that fit any container, with no header or status chip cut' {
        foreach ($item in @($queries | Where-Object { $_.content.visualization -eq 'table' })) {
            $labels = @{}
            foreach ($label in @($item.content.gridSettings.labelSettings)) { $labels[$label.columnId] = $label.label }
            $budget = if ($item.customWidth -and [int]$item.customWidth -le 50) { 58 } else { 115 }
            $sum = 0
            foreach ($formatter in @($item.content.gridSettings.formatters)) {
                $width = [string]$formatter.formatOptions.customColumnWidthSetting
                $width | Should -Match '^\d+fr$' -Because "$($item.name): $($formatter.columnMatch) needs an fr width, because fixed ch widths overflow a narrow container and push columns off screen"
                $fr = [int]($width -replace 'fr$', '')
                $header = if ($labels.ContainsKey($formatter.columnMatch)) { $labels[$formatter.columnMatch] } else { [string]$formatter.columnMatch }
                $fr | Should -BeGreaterOrEqual ($header.Length + 5) -Because "$($item.name): header '$header' is cut off at $width"
                if ($formatter.formatter -eq 18) {
                    $longest = ($formatter.formatOptions.thresholdsGrid | Where-Object { $_.thresholdValue } | ForEach-Object { ([string]$_.thresholdValue).Length } | Measure-Object -Maximum).Maximum
                    $fr | Should -BeGreaterOrEqual ($longest + 6) -Because "$($item.name) chip $($formatter.columnMatch)"
                }
                if ($formatter.formatter -eq 6) { $fr | Should -BeGreaterOrEqual 26 -Because "$($item.name): 26 characters keep the AM/PM of a 12-hour clock from being clipped" }
                $sum += $fr
            }
            $sum | Should -BeLessOrEqual $budget -Because "$($item.name): the column widths add up to $sum characters"
        }
    }

    It 'gives every projected grid column an explicit width, so no column is left to auto-size and widen the grid past its tile' {
        foreach ($item in @($queries | Where-Object { $_.content.visualization -eq 'table' })) {
            $columns = Get-ProjectedColumn $item.content.query
            if (-not $columns) { continue }
            $formatted = @($item.content.gridSettings.formatters | ForEach-Object { [string]$_.columnMatch })
            foreach ($column in $columns) { $formatted | Should -Contain $column -Because "$($item.name) column $column" }
        }
    }

    It 'rounds decimals in grids with an explicit number format and prints percentages as percentages' {
        foreach ($pair in @(@('perf-volumes', 'FreePct'), @('perf-volumes', 'LowestPct'), @('perf-volumes', 'FreeGb'), @('perf-volumes', 'SizeGb'), @('perf-dist', 'SharePct'), @('sql-databases', 'SizeMB'))) {
            $item = $queries | Where-Object name -eq $pair[0]
            $formatter = $item.content.gridSettings.formatters | Where-Object columnMatch -eq $pair[1]
            $formatter.numberFormat.options.maximumFractionDigits | Should -BeLessOrEqual 1 -Because "$($pair[0]) $($pair[1])"
        }
        foreach ($pair in @(@('perf-volumes', 'FreePct'), @('perf-volumes', 'LowestPct'), @('perf-dist', 'SharePct'))) {
            $item = $queries | Where-Object name -eq $pair[0]
            ($item.content.gridSettings.formatters | Where-Object columnMatch -eq $pair[1]).numberFormat.unit | Should -Be 1 -Because "$($pair[0]) $($pair[1]): a bar or heat cell without a percentage format prints 7.100"
        }
    }

    It 'shows policy and initiative display names, never the raw definition GUIDs, one row per policy and initiative' {
        $query = ($arg | Where-Object name -eq 'arc-policy-table').content.query
        $query | Should -Match 'Windows machines should meet requirements of the Azure compute security baseline'
        $query | Should -Match 'Microsoft cloud security benchmark'
        $query | Should -Match 'NIST SP 800-53 Rev\. 5'
        $query | Should -Match 'summarize Assignments = dcount\(AssignmentName\), LastEvaluated = max\(EvaluatedAt\) by Policy, Initiative'
        $query | Should -Match '\| project Policy, Initiative, Assignments, EvaluatedAge = case\('
        $query | Should -Not -Match '(?m)^\| project .*policyDefinitionName'
    }

    It 'keeps the Operating system tile to a short note that fits the tile' {
        $query = ($arg | Where-Object name -eq 'glance-identity').content.query
        $query | Should -Match "replace_string\(OsSku, 'Windows Server ', 'Server '\)"
        $query | Should -Match 'substring\(OsShort, 0, 30\)'
    }

    It 'keeps the identity strip to four tiles so a fifth never wraps alone' {
        $query = ($arg | Where-Object name -eq 'glance-identity').content.query
        @([regex]::Matches($query, "pack\('Label'")).Count | Should -Be 4
        $query | Should -Match "'Role'"
        $query | Should -Match "strcat\('agent v', AgentMajor, ', since ', ChangedText\)"
    }

    It 'keeps chart titles and legend labels short enough not to be cut, and names the level a threshold line marks' {
        foreach ($item in @($la | Where-Object { $_.content.visualization -eq 'barchart' })) {
            $width = if ($item.customWidth) { [int]$item.customWidth } else { 100 }
            $limit = if ($width -le 33) { 28 } elseif ($width -le 50) { 34 } else { 80 }
            $item.content.title.Length | Should -BeLessOrEqual $limit -Because "$($item.name): '$($item.content.title)' is cut off at $width% width"
            foreach ($series in @($item.content.chartSettings.seriesLabelSettings)) { $series.label.Length | Should -BeLessOrEqual 22 -Because "$($item.name) legend '$($series.label)'" }
            $line = $item.content.chartSettings.customThresholdLine
            if ($line) { $item.content.title | Should -Match "line at $line%" -Because "$($item.name): an unlabeled threshold line leaves the reader guessing" }
        }
    }

    It 'prints percentage charts as percentages' {
        foreach ($name in 'perf-cpu-avg', 'perf-cpu-peak', 'perf-mem', 'perf-disk', 'events-heartbeat') {
            ($la | Where-Object name -eq $name).content.chartSettings.ySettings.numberFormatSettings.unit | Should -Be 1 -Because $name
        }
    }

    It 'colours free space on the same thresholds as the Level chip: green at 30% free or more, red under 15%' {
        $volumes = $la | Where-Object name -eq 'perf-volumes'
        $volumes.content.query | Should -Match "FreePct < 15, 'Low free space', FreePct < 30, 'Watch', 'Healthy'"
        foreach ($name in 'FreePct', 'LowestPct') {
            $formatter = $volumes.content.gridSettings.formatters | Where-Object columnMatch -eq $name
            $formatter.formatOptions.palette | Should -Be 'redGreen' -Because $name
            $formatter.formatOptions.min | Should -Be 0 -Because $name
            $formatter.formatOptions.max | Should -Be 30 -Because "$name is full green at 30% free, like the Healthy chip"
        }
    }

    It 'does not contradict itself on the SQL tab: the engine tiles say they describe the host, and the instance message allows for a running SQL Server' {
        ($arg | Where-Object name -eq 'sql-detect').content.query | Should -Match "'SQL Server on host'"
        ($arg | Where-Object name -eq 'sql-instances').content.noDataMessage | Should -Match 'even if SQL Server is running'
    }
}

Describe 'Machine Intelligence Center shows one explanation instead of message-only charts' {
    It 'derives two hidden switches from Log Analytics for the selected machine and time range' {
        foreach ($name in 'Telemetry', 'SqlWorker') {
            $switch = $parameters | Where-Object name -eq $name
            $switch.type | Should -Be 2 -Because $name
            $switch.isHiddenWhenLocked | Should -BeTrue -Because $name
            $switch.isRequired | Should -BeTrue -Because $name
            $switch.queryType | Should -Be 0 -Because $name
            $switch.resourceType | Should -Be 'microsoft.operationalinsights/workspaces' -Because $name
            $switch.timeContextFromParameter | Should -Be 'TimeRange' -Because $name
            $switch.query | Should -Match "split\('\{Machine\}', '/'\)\[-1\]" -Because $name
            $switch.query | Should -Match '\| summarize \w+ = count\(\)' -Because "$name returns exactly one row even when nothing matches"
            $switch.query | Should -Match 'selected = true' -Because $name
        }
        ($parameters | Where-Object name -eq 'Telemetry').query | Should -Match '\bHeartbeat\b'
        ($parameters | Where-Object name -eq 'Telemetry').query | Should -Match "'data'.+'none'"
        ($parameters | Where-Object name -eq 'SqlWorker').query | Should -Match "Source == 'ArcSqlEngineDemo'"
        ($parameters | Where-Object name -eq 'SqlWorker').query | Should -Match "'worker'.+'none'"
    }

    It 'hides every Log Analytics chart, grid and header of a tab behind its switch, so a machine without data gets no chart-height blank band' {
        $tabItems = @($items | Where-Object { $_.name -match '^(perf|software|events|sql)-' })
        foreach ($item in $tabItems) {
            if ($item.name -in 'perf-nodata', 'software-nodata', 'events-nodata', 'sql-noworker', 'sql-detect', 'sql-instances', 'sql-databases', 'sql-header') { continue }
            $parameter = if ($item.name -like 'sql-*') { 'SqlWorker' } else { 'Telemetry' }
            $value = if ($item.name -like 'sql-*') { 'worker' } else { 'data' }
            $item.conditionalVisibility.parameterName | Should -Be $parameter -Because $item.name
            $item.conditionalVisibility.comparison | Should -Be 'isEqualTo' -Because $item.name
            $item.conditionalVisibility.value | Should -Be $value -Because $item.name
        }
        foreach ($name in 'perf-cpu-avg', 'perf-volumes', 'software-chart', 'software-table', 'events-heartbeat', 'events-sources', 'sql-workload', 'sql-events') {
            @($tabItems | Where-Object name -eq $name).Count | Should -Be 1 -Because "$name must be present and hidden when there is nothing to chart"
        }
    }

    It 'shows one specific info message per tab for a machine without data, naming the machine' {
        foreach ($pair in @(@('perf-nodata', 'Telemetry'), @('software-nodata', 'Telemetry'), @('events-nodata', 'Telemetry'), @('sql-noworker', 'SqlWorker'))) {
            $message = $items | Where-Object name -eq $pair[0]
            $message.type | Should -Be 1 -Because $pair[0]
            $message.content.style | Should -Be 'info' -Because $pair[0]
            $message.conditionalVisibility.parameterName | Should -Be $pair[1] -Because $pair[0]
            $message.conditionalVisibility.value | Should -Be 'none' -Because $pair[0]
            $message.content.json | Should -Match '\{Machine\}' -Because $pair[0]
            $message.content.json.Length | Should -BeGreaterThan 120 -Because $pair[0]
        }
        foreach ($name in 'perf-nodata', 'software-nodata', 'events-nodata') { ($items | Where-Object name -eq $name).content.json | Should -Match 'no Azure Monitor Agent|has no Azure Monitor Agent|without the agent' -Because $name }
        ($items | Where-Object name -eq 'sql-noworker').content.json | Should -Match 'ArcSqlEngineDemo'
    }

    It 'keeps the Arc, Defender and SQL inventory visible for a machine without an agent' {
        foreach ($name in 'glance-identity', 'glance-live', 'security-tiles', 'security-open', 'sql-detect', 'sql-instances', 'sql-databases', 'arc-extensions', 'arc-policy-tiles', 'arc-policy-table') {
            $item = $items | Where-Object name -eq $name
            $item.conditionalVisibility.parameterName | Should -Not -Be 'Telemetry' -Because $name
        }
    }
}
