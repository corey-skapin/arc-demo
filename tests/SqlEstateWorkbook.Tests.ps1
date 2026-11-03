BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $path = Join-Path $repo 'workbooks\nseilaz\SQL_Estate_Dashboard.json'
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
    $markdown = (@($items | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.content.json }) -join "`n")

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
        @($parts | ForEach-Object { ($_ -split '=')[0].Trim() })
    }
}

Describe 'SQL Estate Dashboard tells one story and opens populated' {
    It 'is a Notebook/1.0 workbook that keeps the upstream attribution' {
        $book.version | Should -Be 'Notebook/1.0'
        $raw | Should -Match 'Nic Seilaz'
        $raw | Should -Match 'github\.com/nseilaz/AzureArc_Workbooks'
        $raw | Should -Match 'MIT'
    }

    It 'has a working default for every parameter and no workspace picker' {
        foreach ($parameter in $parameters) { $parameter.isRequired | Should -BeTrue -Because $parameter.name }
        @($parameters | Where-Object type -eq 5).Count | Should -Be 0
        $raw | Should -Not -Match 'LogAnalyticsWorkspace'
        ($parameters | Where-Object name -eq 'Subscription').value | Should -Contain 'value::all'
        ($parameters | Where-Object name -eq 'TimeRange').value.durationMs | Should -BeGreaterThan 0
    }

    It 'ships no workspace scope of its own: Phase 11 pins every Log Analytics tile and hidden switch to the deployment workspace at publish' {
        $la.Count | Should -BeGreaterThan 0
        foreach ($item in $la) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $item.name }
        foreach ($parameter in @($parameters | Where-Object { $_.queryType -eq 0 })) { $parameter.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $parameter.name }
        $book.PSObject.Properties.Name | Should -Not -Contain 'fallbackResourceIds'
        $raw | Should -Not -Match '/subscriptions/'
        $raw | Should -Not -Match '(?i)law-[a-z0-9-]+'
    }

    It 'scopes every Resource Graph tile by the subscription picker' {
        foreach ($item in $arg) { @($item.content.crossComponentResources) | Should -Be @('{Subscription}') -Because $item.name }
    }

    It 'keeps Resource Graph queries within what Resource Graph accepts' {
        foreach ($item in $arg) {
            $item.content.query | Should -Not -Match '(?m)^\s*let ' -Because $item.name
            ([regex]::Matches($item.content.query, 'alertsmanagementresources')).Count | Should -BeLessOrEqual 1 -Because $item.name
        }
    }

    It 'shows the Arc inventory and the monitored workload together, workload first read from Azure Monitor events' {
        foreach ($name in 'glance-inventory', 'glance-alert', 'glance-alerts', 'inventory-instances', 'inventory-databases') { $arg.name | Should -Contain $name }
        foreach ($name in 'glance-workload', 'workload-commits', 'workload-latency', 'workload-locks', 'workload-incidents') {
            $query = ($la | Where-Object name -eq $name).content.query
            $query | Should -Match "Source == 'ArcSqlEngineDemo'"
            $query | Should -Match 'EventID in \(6000, 6001, 6201\)|EventID == 6201'
        }
    }

    It 'matches the alert rule by its naming pattern, never by a lab prefix' {
        foreach ($name in 'glance-alert', 'glance-alerts', 'workload-alerts') {
            $query = ($arg | Where-Object name -eq $name).content.query
            $query | Should -Match "-sql-lock-timeout'"
            $query | Should -Not -Match 'arc-demo'
        }
    }

    It 'lists only databases that belong to a registered instance, never orphans of a deleted one' {
        foreach ($name in 'glance-inventory', 'inventory-databases') {
            $query = ($arg | Where-Object name -eq $name).content.query
            $query | Should -Match "join kind=inner \(resources \| where type =~ 'microsoft\.azurearcdata/sqlserverinstances'"
        }
    }
}

Describe 'SQL Estate Dashboard is honest about what it can and cannot show' {
    It 'labels the nested Arc SQL instance experimental and unsupported' {
        $markdown | Should -Match 'Experimental configuration'
        $markdown | Should -Match 'unsupported'
        $markdown | Should -Match 'licence-only'
    }

    It 'makes no Defender claim and does not paint the reported value as an achievement' {
        $markdown | Should -Match 'no Defender for SQL claim'
        $grid = ($arg | Where-Object name -eq 'inventory-instances').content.gridSettings
        ($grid.labelSettings | Where-Object columnId -eq 'Defender').label | Should -Be 'Defender (Arc)'
        $defender = $grid.formatters | Where-Object columnMatch -eq 'Defender'
        ($defender.formatOptions.thresholdsGrid | Where-Object thresholdValue -eq 'Protected').representation | Should -Not -Be 'green'
        $raw | Should -Not -Match '"seriesName":\s*"Protected"'
    }

    It 'carries no unsourced cost, breach or fine figures' {
        $raw | Should -Not -Match '\$\s?\d'
        $raw | Should -Not -Match '(?i)per core|per incident|breach'
    }

    It 'guards the best practices assessment tiles so a missing SqlAssessment_CL table is not an error' {
        foreach ($name in 'bpa-severity', 'bpa-top') {
            $query = ($la | Where-Object name -eq $name).content.query
            $query | Should -Match 'union isfuzzy=true SqlAssessment_CL'
            ([regex]::Matches($query, 'SqlAssessment_CL')).Count | Should -Be 1 -Because "$name must reach the table only through the guarded union"
            ($la | Where-Object name -eq $name).content.noDataMessage | Should -Match 'not enabled'
        }
        $markdown | Should -Match 'not enabled in this lab'
    }

    It 'keeps the version and licence mixes that understand Arc SQL text values' {
        ($arg | Where-Object name -eq 'mix-version').content.query | Should -Match "version has '2022', 'SQL 2022'"
        ($arg | Where-Object name -eq 'mix-licence').content.query | Should -Match "licenseType =~ 'Free'"
    }

    It 'gives every tile a specific message for an empty result' {
        foreach ($item in $queries) {
            $message = [string]$item.content.noDataMessage
            $message.Length | Should -BeGreaterThan 60 -Because $item.name
            $message | Should -Not -Match '^(No results|No data)\.?$' -Because $item.name
        }
    }

    It 'shows an expected or good-news empty result in the blue info style and keeps the amber warning box for an absence that is itself a finding' {
        $calm = 'workload-locks', 'workload-incidents', 'workload-alerts'
        foreach ($name in $calm) { @($queries | Where-Object name -eq $name).Count | Should -Be 1 -Because "$name must exist" }
        foreach ($item in $queries) {
            $expected = if ($item.name -in $calm) { 3 } else { 4 }
            $item.content.noDataMessageStyle | Should -Be $expected -Because "$($item.name): style 3 is the info style and 4 the amber warning box, which reads as a fault"
        }
    }

    It 'follows the time range on every Log Analytics tile and never on Resource Graph tiles' {
        foreach ($item in $la) { $item.content.timeContextFromParameter | Should -Be 'TimeRange' -Because $item.name }
        foreach ($item in $arg) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'timeContextFromParameter' -Because $item.name }
    }
}

Describe 'SQL Estate Dashboard tiles stay readable and mean what they say' {
    It 'keeps tile labels at 18 characters and every other tile text at 30 characters, so nothing is cut at the default tile width' {
        foreach ($item in @($queries | Where-Object { $_.content.visualization -eq 'tiles' })) {
            foreach ($match in [regex]::Matches($item.content.query, "'Label', '([^']*)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because "$($item.name): $($match.Groups[1].Value)" }
            foreach ($line in ($item.content.query -split "`n" | Where-Object { $_ -match "pack\('Label'|Note = " })) {
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

    It 'uses a numeric-looking recovery column with a green-to-red scale where slow recovery is bad' {
        $grid = ($la | Where-Object name -eq 'workload-incidents').content.gridSettings
        $recovery = $grid.formatters | Where-Object columnMatch -eq 'RecoveredAfterSec'
        $recovery.formatter | Should -Be 8
        $recovery.formatOptions.palette | Should -Be 'greenRed'
    }
}

Describe 'SQL Estate Dashboard renders cleanly in the portal' {
    It 'draws every time series as columns with no legend totals, so a parked or silent interval is a break and nothing reads as (Sum)' {
        $charts = @($la | Where-Object { $_.name -like 'workload-*' -and $_.content.visualization -ne 'table' })
        $charts.Count | Should -Be 3
        foreach ($item in $charts) {
            $item.content.visualization | Should -BeIn 'barchart', 'unstackedbar' -Because $item.name
            $item.content.chartSettings.showMetrics | Should -BeFalse -Because "$($item.name) must not show (Sum) totals"
        }
        $raw | Should -Not -Match '"visualization":\s*"timechart"'
    }

    It 'draws lock timeouts and recoveries side by side, not stacked, because a stacked total of the two matches no tile' {
        ($la | Where-Object name -eq 'workload-locks').content.visualization | Should -Be 'unstackedbar'
        foreach ($name in 'workload-commits', 'workload-latency') {
            ($la | Where-Object name -eq $name).content.visualization | Should -Be 'barchart' -Because "$name has one series, so nothing can stack"
        }
        @(($la | Where-Object name -eq 'workload-locks').content.chartSettings.seriesLabelSettings).Count | Should -Be 2
    }

    It 'plots latency as one series so columns can never be misread as a stack of an average on a maximum' {
        $query = ($la | Where-Object name -eq 'workload-latency').content.query
        $query | Should -Match 'make-series Slowest = max\(Elapsed\)'
        $query | Should -Not -Match 'Average'
        @(($la | Where-Object name -eq 'workload-latency').content.chartSettings.seriesLabelSettings).Count | Should -Be 1
    }

    It 'gives every workload chart a short title and a short legend below it, so nothing is cut at one third of the page width' {
        foreach ($name in 'workload-commits', 'workload-latency', 'workload-locks') {
            $item = $la | Where-Object name -eq $name
            $item.customWidth | Should -Be '33' -Because $name
            $item.content.title.Length | Should -BeLessOrEqual 28 -Because "$name '$($item.content.title)' is cut off at 33% width"
            $chart = $item.content.chartSettings
            $chart.showLegend | Should -BeTrue -Because $name
            $chart.simpleLegendSettings.position | Should -Be 'bottom' -Because $name
            @($chart.seriesLabelSettings).Count | Should -BeGreaterThan 0 -Because $name
            foreach ($series in $chart.seriesLabelSettings) { $series.label.Length | Should -BeLessOrEqual 22 -Because "$name $($series.seriesName)" }
        }
        $locks = ($la | Where-Object name -eq 'workload-locks').content.chartSettings
        ($locks.seriesLabelSettings | Where-Object seriesName -like 'Lock timeout*').color | Should -Be 'redBright'
    }

    It 'shows the edition, version and licence mix as tiles, not single-slice charts' {
        foreach ($name in 'mix-edition', 'mix-version', 'mix-licence') {
            $item = $arg | Where-Object name -eq $name
            $item.content.visualization | Should -Be 'tiles' -Because $name
            (Get-ProjectedColumn $item.content.query) | Should -Be @('Label', 'Value', 'Note') -Because $name
        }
        $raw | Should -Not -Match '"visualization":\s*"piechart"'
    }

    It 'leaves no table at the Small size, which reserves a fixed block of blank space under a short table, and bounds every table' {
        $tables = @($queries | Where-Object { $_.content.visualization -eq 'table' })
        $tables.Count | Should -BeGreaterOrEqual 4
        foreach ($item in $tables) {
            $item.content.size | Should -Be 3 -Because $item.name
            $bounded = ($item.content.query -match '\| take \d+') -or ($item.content.gridSettings.rowLimit -gt 0)
            $bounded | Should -BeTrue -Because "$($item.name) must be bounded when it is shown at the Full size"
        }
    }

    It 'formats every date and time column as a readable local date instead of a raw ISO string' {
        foreach ($pair in @(@('workload-incidents', 'Detected'), @('workload-alerts', 'Raised'))) {
            $item = $queries | Where-Object name -eq $pair[0]
            $formatter = $item.content.gridSettings.formatters | Where-Object columnMatch -eq $pair[1]
            $formatter.formatter | Should -Be 6 -Because "$($pair[0]) $($pair[1])"
            $formatter.dateFormat.formatName | Should -Be 'shortDateTimeNoMsPattern' -Because "$($pair[0]) $($pair[1])"
            $formatter.dateFormat.showUtcTime | Should -BeNullOrEmpty -Because "$($pair[0]) $($pair[1]): null means local time"
        }
    }

    It 'reports the latest alert and the resolution as relative ages like every other tile, not UTC clock times' {
        $query = ($arg | Where-Object name -eq 'glance-alerts').content.query
        $query | Should -Match "strcat\('latest ', RaisedText\)"
        $query | Should -Not -Match 'UTC|format_datetime'
        ($arg | Where-Object name -eq 'workload-alerts').content.query | Should -Match "ResolvedAge = iff\(isnull\(ResolvedAt\), ''"
    }

    It 'shows one state on the latest-alert tile, never two states side by side' {
        $query = ($arg | Where-Object name -eq 'glance-alerts').content.query
        $query | Should -Match "pack\('Label', 'Latest alert', 'Value', Condition, 'Note', Sev, 'Order', 2\)"
        $query | Should -Not -Match "strcat\(AlertState"
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

    It 'keeps the incident grid to one full-width row without the identifier columns that only widen it' {
        $item = $la | Where-Object name -eq 'workload-incidents'
        $item.PSObject.Properties.Name | Should -Not -Contain 'customWidth'
        @($item.content.gridSettings.formatters).Count | Should -BeLessOrEqual 8
        $raw | Should -Not -Match '"columnMatch":\s*"IncidentId"'
    }

    It 'keeps the instance grid to the columns that matter, labelling the Defender value as the one Arc reports' {
        $item = $arg | Where-Object name -eq 'inventory-instances'
        @($item.content.gridSettings.formatters | ForEach-Object { $_.columnMatch }) | Should -Be @('Instance', 'Version', 'Edition', 'Licence', 'Status', 'Defender', 'InventoryAge')
    }
}

Describe 'SQL Estate Dashboard shows no empty assessment tiles while assessment is not enabled' {
    It 'derives a hidden switch from a guarded read of the assessment table for the time range' {
        $switch = $parameters | Where-Object name -eq 'BpaMode'
        $switch.type | Should -Be 2
        $switch.isHiddenWhenLocked | Should -BeTrue
        $switch.isRequired | Should -BeTrue
        $switch.queryType | Should -Be 0
        $switch.resourceType | Should -Be 'microsoft.operationalinsights/workspaces'
        $switch.timeContextFromParameter | Should -Be 'TimeRange'
        $switch.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources'
        $switch.query | Should -Match 'union isfuzzy=true SqlAssessment_CL'
        ([regex]::Matches($switch.query, 'SqlAssessment_CL')).Count | Should -Be 1
        $switch.query | Should -Match '\| summarize Rows = count\(\)'
        $switch.query | Should -Match "'data'.+'none'"
        $switch.query | Should -Match 'selected = true'
    }

    It 'shows the assessment charts only when assessment data exists and an info note explaining why not otherwise' {
        foreach ($name in 'bpa-severity', 'bpa-top') {
            $item = $items | Where-Object name -eq $name
            $item.conditionalVisibility.parameterName | Should -Be 'BpaMode' -Because $name
            $item.conditionalVisibility.value | Should -Be 'data' -Because $name
        }
        $off = $items | Where-Object name -eq 'bpa-off'
        $off.conditionalVisibility.parameterName | Should -Be 'BpaMode'
        $off.conditionalVisibility.value | Should -Be 'none'
        $off.content.style | Should -Be 'info'
        $off.content.json | Should -Match 'not enabled in this lab'
        $off.content.json | Should -Match 'SqlAssessment_CL'
        ($items | Where-Object name -eq 'bpa-on').conditionalVisibility.value | Should -Be 'data'
    }
}
