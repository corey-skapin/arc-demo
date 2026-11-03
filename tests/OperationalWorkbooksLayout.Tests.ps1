BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\OperationalWorkbooks.psm1') -Force
    $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
    $workspaceId = "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture"
    $machines = @(@{ id = "$scope/providers/Microsoft.HybridCompute/machines/parent" }, @{ id = "$scope/providers/Microsoft.HybridCompute/machines/guest" })
    $books = @{}
    foreach ($purpose in 'capacity', 'optimisation') {
        $books[$purpose] = (Get-DemoOperationalWorkbook -Purpose $purpose -WorkspaceResourceId $workspaceId -Machines $machines -DisplayUtcOffsetHours 10.5).SerializedData | ConvertFrom-Json -Depth 100
    }

    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) { $item; if ($item.type -eq 12) { Get-WorkbookItem $item.content.items } }
    }
    function Get-QueryItem($Purpose) { @(Get-WorkbookItem $books[$Purpose].items | Where-Object { $_.type -eq 3 }) }
    function Get-JsonNode($Node) {
        if ($Node -is [System.Collections.IList]) { foreach ($child in $Node) { Get-JsonNode $child } }
        elseif ($Node -is [pscustomobject]) { $Node; foreach ($property in $Node.PSObject.Properties) { Get-JsonNode $property.Value } }
    }
    function Get-Table($Purpose) { @(Get-QueryItem $Purpose | Where-Object { $_.content.visualization -eq 'table' }) }
    function Get-Formatter($Item) { foreach ($formatter in @($Item.content.gridSettings.formatters)) { if ($formatter) { $formatter } } }
    function Get-Label($Item, $Formatter) {
        $match = @($Item.content.gridSettings.labelSettings) | Where-Object { $_ -and $_.columnId -eq $Formatter.columnMatch } | Select-Object -First 1
        if ($match) { $match.label } else { $Formatter.columnMatch }
    }
    # A fixed-size tile item shows about four tiles per row; count the rows of the datatable that drives it.
    function Get-TileRowCount([string]$Query) {
        $table = [regex]::Match($Query, 'datatable\(SortKey:long(?<schema>[^)]*)\)\s*\[(?<body>[^\]]*)\]')
        if (-not $table.Success) { return -1 }
        if ($table.Groups['schema'].Value -match 'Label') { return [regex]::Matches($table.Groups['body'].Value, '(?m)^\s*\d+,\s*"').Count }
        ($table.Groups['body'].Value -split ',').Count
    }
}

Describe 'Operational workbooks lay out cleanly in the portal' {
    It '<Purpose>: sizes every grid column in proportional fr units that fit any container' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($item in Get-Table $Purpose) {
            $title = $item.content.title
            $budget = if ($item.customWidth -and [int]$item.customWidth -le 50) { 58 } else { 115 }
            $sum = 0
            $fixed = 0
            foreach ($formatter in Get-Formatter $item) {
                $width = $formatter.formatOptions.customColumnWidthSetting
                # The 12 two-hour cells of the activity heat map are fixed characters: a flexible column cannot shrink below the portal's minimum, so a grid of narrow flexible cells overflows even a very wide screen.
                if ($item.name -eq 'sched-heatmap' -and $width -match '^\d+ch$') { $fixed += [int]($width -replace 'ch$', ''); continue }
                $width | Should -Match '^\d+fr$' -Because "${title}: $($formatter.columnMatch) needs an fr width, because fixed ch widths overflow a narrow container and push columns off screen"
                $sum += [int]($width -replace 'fr$', '')
            }
            $sum | Should -BeLessOrEqual $budget -Because "${title}: the column widths add up to $sum"
            if ($fixed) {
                $fixed | Should -BeLessOrEqual 150 -Because "${title}: the fixed columns add up to $fixed characters, about 1,030 px: a wider heat map scrolls on a 1,664 px laptop screen"
                $sum | Should -BeGreaterThan 0 -Because "${title}: one flexible column must take the width that is left"
            }
        }
    }

    It 'gives the activity heat map 12 fixed two-hour blocks, each wide enough for its header and sort arrow, and lets the machine column take the rest' {
        $item = Get-Table optimisation | Where-Object name -eq 'sched-heatmap'
        $blocks = @(Get-Formatter $item | Where-Object { $_.columnMatch -match '^[BH]\d\d$' })
        @($blocks | Where-Object { $_.columnMatch -match '^H' }).Count | Should -Be 0 -Because '24 hourly cells need about 1,900 px and scrolled sideways on a laptop screen'
        @($blocks | ForEach-Object columnMatch) | Should -Be @(0..11 | ForEach-Object { 'B{0:00}' -f $_ })
        @($blocks | ForEach-Object { Get-Label $item $_ }) | Should -Be @(0..11 | ForEach-Object { '{0:00}-{1:00}' -f (2 * $_), (2 * $_ + 1) }) -Because 'each block is named by the two local hours it covers, midnight to 02:00 first'
        $widths = @($blocks | ForEach-Object { $_.formatOptions.customColumnWidthSetting })
        @($widths | Select-Object -Unique).Count | Should -Be 1 -Because 'the 12 blocks read as one even scale'
        $widths[0] | Should -Match '^\d+ch$'
        [int]($widths[0] -replace 'ch$', '') | Should -BeGreaterOrEqual 11 -Because 'a five-character header (00-01) needs its sort arrow and the cell padding: header + 6, the rule the Estate grids proved in the portal'
        $machine = Get-Formatter $item | Where-Object columnMatch -eq 'Machine'
        $machine.formatOptions.customColumnWidthSetting | Should -Be '1fr'
        $idle = Get-Formatter $item | Where-Object columnMatch -eq 'IdleSharePct'
        (Get-Label $item $idle) | Should -Be 'Idle share' -Because 'the column holds a percentage of hours, so a label of Idle hours reads like a count'
        $idle.formatOptions.customColumnWidthSetting | Should -Be '15ch'
    }

    It 'describes the heat map as two-hour blocks in its title and note, not as hours' {
        $item = Get-Table optimisation | Where-Object name -eq 'sched-heatmap'
        $item.content.title | Should -Match 'two-hour block'
        $item.content.title | Should -Not -Match 'by local hour'
        $item.content.description | Should -Match 'two-hour block'
        $item.content.description | Should -Match 'no samples in either hour'
        $item.content.description | Should -Match 'Idle share counts full hours'
    }

    It 'builds the block cells in the query as the average of every sample in the two local hours, blank only when neither hour has any' {
        $query = (Get-Table optimisation | Where-Object name -eq 'sched-heatmap').content.query
        foreach ($block in 0..11) {
            $query | Should -Match ('B{0:00} = round\(avgif\(Value, Hr in \({1}, {2}\)\), 0\)' -f $block, (2 * $block), (2 * $block + 1)) -Because "block $block covers hours $(2 * $block) and $(2 * $block + 1)"
            $query | Should -Match ('B{0:00} = Clean\(B{0:00}\)' -f $block) -Because 'a block with no samples is a null, not the text NaN'
        }
        $query | Should -Not -Match '\bH\d\d\b' -Because 'no hourly column is left behind'
        $query | Should -Match 'hourofday\(TimeGenerated \+ UtcOffset\)' -Because 'blocks follow the display time zone, as the hourly cells did'
    }

    It '<Purpose>: gives every column a header that is not cut off' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($item in Get-Table $Purpose) {
            foreach ($formatter in Get-Formatter $item) {
                $label = Get-Label $item $formatter
                $setting = $formatter.formatOptions.customColumnWidthSetting
                # The flexible machine column of the heat map takes whatever width is left, which is far more than its header needs.
                if ($item.name -eq 'sched-heatmap' -and $formatter.columnMatch -eq 'Machine') { continue }
                $width = [int]($setting -replace '(fr|ch)$', '')
                # A short heat-map header (a two-hour block such as 00-01) needs its sort arrow and the cell padding as well, so it gets header + 6 like the Estate grids (header + 4 showed only the first digit in the portal).
                $needed = if ($formatter.columnMatch -match '^[BH]\d\d$') { $label.Length + 6 } else { $label.Length + 5 }
                $needed | Should -BeLessOrEqual $width -Because "$($item.content.title): header '$label' is cut off at $setting"
            }
        }
    }

    It '<Purpose>: fits every table to its rows (Full size) so no blank band follows a short table' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($item in Get-Table $Purpose) {
            $item.content.size | Should -Be 3 -Because "$($item.content.title): a Small grid reserves about 330 px even with one row"
        }
    }

    It '<Purpose>: bounds the tables that are not one row per machine' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $bounded = @{ 'disk-volumes' = 50; 'detail-card' = 40 }
        foreach ($name in $bounded.Keys) {
            $item = Get-QueryItem $Purpose | Where-Object name -eq $name
            if (-not $item) { continue }
            $take = [regex]::Matches($item.content.query, '\|\s*take\s+(\d+)') | Select-Object -Last 1
            $take | Should -Not -BeNullOrEmpty -Because "$name is a Full-size table and must be capped"
            [int]$take.Groups[1].Value | Should -BeLessOrEqual $bounded[$name]
        }
    }

    It '<Purpose>: prints percentage bars as percentages, with the colour direction that matches good and bad' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $goodWhenHigh = 'FreePct', 'FreeNowPct', 'MinPct', 'SamplingPct'
        foreach ($item in Get-Table $Purpose) {
            foreach ($formatter in Get-Formatter $item | Where-Object { $_.formatter -eq 8 -and $_.formatOptions.palette -in 'redGreen', 'greenRed' }) {
                $because = "$($item.content.title): $($formatter.columnMatch)"
                $expected = if ($formatter.columnMatch -in $goodWhenHigh) { 'redGreen' } else { 'greenRed' }
                $formatter.formatOptions.palette | Should -Be $expected -Because "$because must never be green on a bad number"
                $formatter.formatOptions.min | Should -Be 0 -Because $because
                $formatter.formatOptions.max | Should -Be 100 -Because $because
                $formatter.numberFormat.unit | Should -Be 1 -Because "$because would print 18.600 without a number format"
                $formatter.numberFormat.options.maximumFractionDigits | Should -Be 1 -Because $because
            }
        }
    }

    It 'keeps the Optimisation utilisation bars neutral: low utilisation is the flag, so it is never painted green or red' {
        foreach ($item in Get-Table optimisation | Where-Object name -ne 'detail-evidence') {
            foreach ($formatter in Get-Formatter $item | Where-Object { $_.formatter -eq 8 }) {
                $formatter.formatOptions.palette | Should -BeIn 'blue', 'blueDark' -Because "$($item.content.title): $($formatter.columnMatch) is a fact about use, not a health signal"
            }
        }
    }

    It '<Purpose>: prints whole numbers plain and fractions to at most one decimal, never padded and never abbreviated' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $formats = 0
        foreach ($item in Get-Table $Purpose) {
            foreach ($formatter in Get-Formatter $item | Where-Object { $_.PSObject.Properties['numberFormat'] -and $_.formatter -eq 1 }) {
                $formats++
                $formatter.numberFormat.unit | Should -Be 0 -Because "$($item.content.title): $($formatter.columnMatch) must not use the Count unit, which abbreviates 3,000 to 3 K beside a plain 747"
                $options = $formatter.numberFormat.options
                $options.minimumFractionDigits | Should -Be 0 -Because "$($item.content.title): $($formatter.columnMatch) must read 52 like the text beside it, not 52.0"
                $options.maximumFractionDigits | Should -Be 1
                $options.useGrouping | Should -Be $false -Because 'the text in the tiles never groups digits'
            }
        }
        $formats | Should -BeGreaterThan 0
    }

    It '<Purpose>: uses no abbreviating number unit anywhere' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($node in Get-JsonNode $books[$Purpose].items | Where-Object { $_.PSObject.Properties['numberFormat'] }) {
            $node.numberFormat.unit | Should -BeIn 0, 1 -Because "$($node.columnMatch): only plain numbers and percentages are used"
        }
    }

    It '<Purpose>: shows every date and time column in local time, wide enough to read' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $dates = 0
        foreach ($item in Get-Table $Purpose) {
            foreach ($formatter in Get-Formatter $item | Where-Object { $_.formatter -eq 6 }) {
                $dates++
                $formatter.dateFormat.PSObject.Properties.Name | Should -Contain 'showUtcTime' -Because $item.content.title
                $formatter.dateFormat.showUtcTime | Should -BeNullOrEmpty -Because "$($item.content.title): null means local time"
                $formatter.dateFormat.formatName | Should -Be 'shortDateTimeNoMsPattern'
                [int]($formatter.formatOptions.customColumnWidthSetting -replace 'fr$', '') | Should -BeGreaterOrEqual 26 -Because "$($item.content.title): 26 characters keep the AM/PM of a 12-hour clock from being clipped"
            }
        }
        $dates | Should -BeGreaterOrEqual 2
    }

    It '<Purpose>: states no raw UTC time anywhere a presenter reads it' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($item in Get-QueryItem $Purpose) {
            $code = (($item.content.query -split "`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            $code | Should -Not -Match '\bUTC\b' -Because "$($item.name): a tile or cell must not tell the presenter a time in UTC"
        }
        foreach ($item in Get-WorkbookItem $books[$Purpose].items | Where-Object { $_.type -eq 1 }) {
            $item.content.json | Should -Not -Match '\d\d:\d\d(:\d\d)? UTC' -Because "$($item.name): a footer time is in the display offset"
        }
    }

    It '<Purpose>: draws time series as column charts whose gaps stay blank, with no legend totals' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $charts = @(Get-QueryItem $Purpose | Where-Object { $_.content.visualization -in 'barchart', 'unstackedbar', 'timechart', 'linechart', 'areachart', 'categoricalbar' })
        $charts.Count | Should -BeGreaterOrEqual 5
        foreach ($item in $charts) {
            $item.content.visualization | Should -BeIn 'barchart', 'unstackedbar' -Because "$($item.name): a line interpolates across parked days and draws a missing sample as zero"
            $item.content.chartSettings.showMetrics | Should -Be $false -Because "$($item.name): legend totals read as (Sum) and contradict never summing"
            if ($item.content.query -match 'make-series') {
                $item.content.query | Should -Match 'default = real\(null\)' -Because "$($item.name): missing is never zero"
                $item.content.query | Should -Not -Match 'default = 0' -Because $item.name
                $item.content.chartSettings.ySettings.min | Should -Be 0 -Because $item.name
                $single = $item.content.chartSettings.PSObject.Properties['seriesLabelSettings']
                if ($single) {
                    $item.content.visualization | Should -Be 'barchart' -Because "$($item.name): one series per chart"
                    $item.content.chartSettings.showLegend | Should -Be $false -Because $item.name
                } else {
                    $item.content.visualization | Should -Be 'unstackedbar' -Because "$($item.name): a stacked chart would add percentages across machines"
                    $item.content.chartSettings.showLegend | Should -Be $true -Because $item.name
                }
                if ($item.content.chartSettings.ySettings.PSObject.Properties['max']) {
                    $item.content.chartSettings.ySettings.max | Should -Be 100 -Because $item.name
                    $item.content.chartSettings.ySettings.numberFormatSettings.unit | Should -Be 1 -Because "$($item.name): a percentage axis without a unit shows bare numbers"
                }
            }
        }
    }

    It '<Purpose>: names the threshold line of every percentage chart with a defined parameter' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        foreach ($item in Get-QueryItem $Purpose | Where-Object { $_.content.visualization -in 'barchart', 'unstackedbar' -and $_.content.chartSettings.PSObject.Properties['customThresholdLine'] }) {
            $item.content.chartSettings.customThresholdLine | Should -BeIn '{CpuHigh}', '{MemHigh}', '{DiskLow}'
        }
    }

    It '<Purpose>: colours no count tile and keeps four or fewer tiles on a row' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $tiles = @(Get-QueryItem $Purpose | Where-Object { $_.content.visualization -eq 'tiles' })
        $tiles.Count | Should -BeGreaterOrEqual 3
        foreach ($item in $tiles) {
            $settings = $item.content.tileSettings
            $settings.titleContent.columnMatch | Should -Be 'Label'
            $settings.secondaryContent.columnMatch | Should -Be 'Note'
            $settings.leftContent.columnMatch | Should -Be 'Value'
            if ($settings.leftContent.formatter -eq 12) {
                $settings.leftContent.formatOptions.palette | Should -Be 'none' -Because "$($item.name): the auto palette gives a count tile an arbitrary left-bar colour beside the status dot"
            }
            if ($settings.PSObject.Properties['size'] -and $settings.size -eq 'auto') { continue }
            $rows = Get-TileRowCount $item.content.query
            $rows | Should -BeGreaterThan 0 -Because "$($item.name): a tile item is driven by a datatable"
            $rows | Should -BeLessOrEqual 4 -Because "$($item.name): a fifth fixed-size tile wraps alone onto the next row"
        }
    }

    It 'splits the five assessment tiles and the six review tiles into two rows' {
        $names = @($books['capacity'].items | ForEach-Object name)
        $names.IndexOf('overview-tiles-gaps') | Should -Be ($names.IndexOf('overview-tiles') + 1)
        $names = @(Get-WorkbookItem $books['optimisation'].items | ForEach-Object name)
        $names.IndexOf('summary-tiles-hygiene') | Should -Be ($names.IndexOf('summary-tiles') + 1)
    }

    It 'shows the scope and evidence tiles as big numerals like the assessment tiles, not small grey text' {
        $scope = Get-QueryItem capacity | Where-Object name -eq 'scope-tiles'
        $scope.content.tileSettings.leftContent.formatter | Should -Be 12
        $scope.content.tileSettings.leftContent.formatOptions.palette | Should -Be 'none'
        $scope.content.query | Should -Not -Match 'Value = case\([^)]*tostring\(' -Because 'a text value renders small and grey'
    }

    It 'splits the scenario into two rows of three tiles whose captions fit a tile' {
        $names = @(Get-WorkbookItem $books['optimisation'].items | ForEach-Object name)
        $names.IndexOf('scenario-result-tiles') | Should -Be ($names.IndexOf('scenario-tiles') + 1)
        $items = Get-QueryItem optimisation
        ($items | Where-Object name -eq 'scenario-tiles').content.query | Should -Match 'SortKey <= 3'
        ($items | Where-Object name -eq 'scenario-result-tiles').content.query | Should -Match 'SortKey > 3'
        $fragment = Get-Content (Join-Path $repo 'workbooks\queries\operational-scenario.kql') -Raw
        $body = [regex]::Match($fragment, '(?s)Note = case\((?<body>.*)\);').Groups['body'].Value
        $captions = @([regex]::Matches($body, '"(?<text>[^"]+)"') | ForEach-Object { $_.Groups['text'].Value })
        $captions.Count | Should -BeGreaterOrEqual 6
        foreach ($caption in $captions) { $caption.Length | Should -BeLessOrEqual 46 -Because "'$caption' is cut off at the edge of a tile" }
        $labels = @([regex]::Matches($fragment, '(?m)^\s*\d,\s*"(?<l>[^"]+)"') | ForEach-Object { $_.Groups['l'].Value })
        $labels.Count | Should -Be 6
        foreach ($label in $labels) { $label.Length | Should -BeLessOrEqual 22 -Because "'$label' is cut off at the edge of a tile" }
    }

    It '<Purpose>: keeps parameter labels short enough not to be cut off' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $parameters = @(Get-WorkbookItem $books[$Purpose].items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
        $parameters.Count | Should -BeGreaterThan 8
        foreach ($parameter in $parameters) {
            ([string]$parameter.label).Length | Should -BeLessOrEqual 20 -Because "the parameter bar cuts '$($parameter.label)' off"
        }
    }

    It 'reads a machine with no telemetry grey in the coverage matrix, and one missing counter amber' {
        $matrix = Get-Table capacity | Where-Object name -eq 'method-matrix'
        foreach ($column in 'CPU', 'Memory', 'AvailableMemory', 'DiskFree') {
            $rules = @{}
            foreach ($rule in (Get-Formatter $matrix | Where-Object columnMatch -eq $column).formatOptions.thresholdsGrid) { $rules[[string]$rule.thresholdValue] = $rule.representation }
            $rules['no telemetry'] | Should -Be 'gray' -Because "${column}: no telemetry is grey everywhere else"
            $rules['missing'] | Should -Be 'orange' -Because "${column}: one counter missing on a machine that reports is an evidence gap, not a failure"
        }
    }

    It 'wraps the review card by part, so no line starts or ends on a separator' {
        $card = Get-QueryItem optimisation | Where-Object name -eq 'detail-card'
        $card.content.query | Should -Not -Match '"  \|  "' -Because 'a wrapped line can end on the separator'
        $card.content.query | Should -Match 'mv-expand with_itemindex=PartNo'
    }

    It 'reads a status column with the colours defined for it, not an auto colour' {
        $candidates = Get-QueryItem optimisation | Where-Object name -eq 'candidates'
        $evidence = Get-Formatter $candidates | Where-Object columnMatch -eq 'Evidence'
        $evidence.formatter | Should -Be 18
        $rules = @{}
        foreach ($rule in $evidence.formatOptions.thresholdsGrid) { $rules[[string]$rule.thresholdValue] = $rule.representation }
        $rules['Adequate'] | Should -Be 'green'
        $rules['Limited'] | Should -Be 'orange'
        $rules['No telemetry'] | Should -Be 'gray'
        foreach ($purpose in 'capacity', 'optimisation') {
            foreach ($item in Get-Table $purpose) {
                foreach ($formatter in Get-Formatter $item | Where-Object { $_.formatter -eq 18 }) {
                    @($formatter.formatOptions.thresholdsGrid).Count | Should -BeGreaterThan 1 -Because "$($item.content.title): $($formatter.columnMatch) needs its colour rules"
                }
            }
        }
    }

    It 'explains the selected machine in the Capacity detail with a wrapped Why table and paired CPU columns' {
        $items = Get-QueryItem capacity
        ($items | Where-Object name -eq 'detail-why').content.size | Should -Be 3
        foreach ($name in 'detail-cpu-p95', 'detail-cpu-peak') {
            $chart = $items | Where-Object name -eq $name
            $chart.customWidth | Should -Be '50'
            $chart.content.visualization | Should -Be 'barchart'
        }
        $items.name | Should -Not -Contain 'detail-cpu'
    }

    It 'keeps tile captions short enough for a fixed-size tile' {
        # A fixed tile is about 160 px wide and shares its width with the big number: the caption names one machine and a count, never a list.
        foreach ($name in 'scope-tiles', 'overview-tiles', 'overview-tiles-gaps') {
            $item = Get-QueryItem capacity | Where-Object name -eq $name
            $item.content.query | Should -Not -Match 'array_slice\(' -Because "$name must not print a list of machine names"
        }
        foreach ($name in 'summary-tiles', 'summary-tiles-hygiene') {
            $item = Get-QueryItem optimisation | Where-Object name -eq $name
            $item.content.query | Should -Not -Match 'array_slice\(' -Because "$name must not print a list of machine names"
        }
    }

    It 'renders the Optimisation review card as a Full-size table next to paired CPU columns' {
        $items = Get-QueryItem optimisation
        ($items | Where-Object name -eq 'detail-card').content.size | Should -Be 3
        foreach ($name in 'detail-cpu-p95', 'detail-cpu-peak', 'detail-mem-pct', 'detail-disk') {
            ($items | Where-Object name -eq $name).customWidth | Should -Be '50'
        }
    }

    It 'labels the display offset instead of calling a local time UTC' {
        Get-DemoUtcOffsetLabel -Hours 0 | Should -Be 'UTC'
        Get-DemoUtcOffsetLabel -Hours 10.5 | Should -Be 'UTC+10:30'
        Get-DemoUtcOffsetLabel -Hours -5 | Should -Be 'UTC-5'
        Get-DemoUtcOffsetLabel -Hours 5.75 | Should -Be 'UTC+5:45'
        Get-DemoUtcOffsetLabel -Hours 14 | Should -Be 'UTC+14'
        $scopeNote = (Get-WorkbookItem $books['capacity'].items | Where-Object { $_.type -eq 1 -and $_.content.json -match 'Roster and tags published' }).content.json
        $scopeNote | Should -Match 'published \d{4}-\d\d-\d\d \d\d:\d\d \(UTC\+10:30\)'
        $stamp = [regex]::Match($scopeNote, 'published (?<t>\d{4}-\d\d-\d\d \d\d:\d\d)').Groups['t'].Value
        $shown = [datetime]::ParseExact($stamp, 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
        [math]::Abs(($shown - [datetime]::UtcNow.AddHours(10.5)).TotalMinutes) | Should -BeLessThan 5
    }

    It 'refuses a query item that has no layout entry and a layout entry that names no item' {
        InModuleScope OperationalWorkbooks {
            $orphan = @([pscustomobject]@{ type = 3; name = 'orphan'; content = [pscustomobject]@{ query = 'x'; visualization = 'table' } })
            { Set-DemoOperationalLayout -Items $orphan -Layout ([pscustomobject]@{}) } | Should -Throw '*no entry for workbook item orphan*'
            $layout = [pscustomobject]@{ orphan = [pscustomobject]@{ customWidth = '50' }; ghost = [pscustomobject]@{ customWidth = '50' } }
            { Set-DemoOperationalLayout -Items $orphan -Layout $layout } | Should -Throw '*ghost*'
        }
    }

    It 'refuses a column width unit other than fr or ch' {
        InModuleScope OperationalWorkbooks {
            $item = [pscustomobject]@{ type = 3; name = 'grid'; content = [pscustomobject]@{ query = 'x'; visualization = 'table' } }
            $layout = [pscustomobject]@{ grid = [pscustomobject]@{ table = [pscustomobject]@{ size = 3; columns = @([pscustomobject]@{ name = 'A'; kind = 'text'; width = 5; unit = 'px' }) } } }
            { Set-DemoOperationalLayout -Items @($item) -Layout $layout } | Should -Throw "*Unknown width unit 'px'*"
        }
    }

    It 'refuses a status column that has no colour rules' {
        InModuleScope OperationalWorkbooks {
            $item = [pscustomobject]@{ type = 3; name = 'grid'; content = [pscustomobject]@{ query = 'x'; visualization = 'table' } }
            $layout = [pscustomobject]@{ grid = [pscustomobject]@{ table = [pscustomobject]@{ size = 3; columns = @([pscustomobject]@{ name = 'State'; kind = 'status'; width = 20 }) } } }
            { Set-DemoOperationalLayout -Items @($item) -Layout $layout } | Should -Throw '*State*colour rules*'
        }
    }

    It 'refuses a date column too narrow to show its clock' {
        InModuleScope OperationalWorkbooks {
            $item = [pscustomobject]@{ type = 3; name = 'grid'; content = [pscustomobject]@{ query = 'x'; visualization = 'table' } }
            $layout = [pscustomobject]@{ grid = [pscustomobject]@{ table = [pscustomobject]@{ size = 3; columns = @([pscustomobject]@{ name = 'When'; kind = 'date'; width = 12 }) } } }
            { Set-DemoOperationalLayout -Items @($item) -Layout $layout } | Should -Throw '*26fr*'
        }
    }
}
