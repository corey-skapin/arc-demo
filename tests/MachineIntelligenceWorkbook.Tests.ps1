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

    It 'ships no workspace scope of its own: Phase 11 pins every Log Analytics tile to the deployment workspace at publish' {
        foreach ($item in $la) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $item.name }
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
        foreach ($name in 'perf-cpu', 'perf-mem', 'perf-avail') { ($la | Where-Object name -eq $name).content.query | Should -Not -Match 'InsightsMetrics' -Because $name }
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
        foreach ($name in 'perf-cpu', 'perf-mem', 'perf-avail', 'perf-disk', 'perf-dist', 'perf-volumes', 'events-heartbeat', 'events-sources') {
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
    It 'keeps tile labels at 18 characters and literal notes at 40 characters' {
        foreach ($item in @($queries | Where-Object { $_.content.visualization -eq 'tiles' })) {
            foreach ($match in [regex]::Matches($item.content.query, "'Label', '([^']*)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because "$($item.name): $($match.Groups[1].Value)" }
            foreach ($match in [regex]::Matches($item.content.query, "'Note', '([^']*)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 40 -Because "$($item.name): $($match.Groups[1].Value)" }
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
        foreach ($name in 'perf-cpu', 'perf-mem', 'perf-disk', 'events-heartbeat') {
            $chart = ($la | Where-Object name -eq $name).content.chartSettings.ySettings
            $chart.min | Should -Be 0 -Because $name
            $chart.max | Should -Be 100 -Because $name
        }
    }
}
