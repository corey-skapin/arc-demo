BeforeDiscovery {
    $books = @(
        @{ Name = 'Asset Inventory'; Path = 'workbooks\arc-asset-inventory.workbook.json' }
        @{ Name = 'Compliance, Security & Governance'; Path = 'workbooks\arc-compliance.workbook.json' }
        @{ Name = 'Governance & Compliance (experimental)'; Path = 'workbooks\arc-governance.workbook.json' }
    )
    $dateColumns = @(
        @{ Path = 'workbooks\arc-asset-inventory.workbook.json'; Tile = 'Server inventory'; Column = 'LastStatusChange' }
        @{ Path = 'workbooks\arc-asset-inventory.workbook.json'; Tile = 'Recent software changes'; Column = 'LastChange' }
        @{ Path = 'workbooks\arc-asset-inventory.workbook.json'; Tile = 'Last heartbeat by server'; Column = 'LastHeartbeat' }
        @{ Path = 'workbooks\arc-compliance.workbook.json'; Tile = 'Defender for Cloud alerts'; Column = 'Detected' }
        @{ Path = 'workbooks\arc-compliance.workbook.json'; Tile = 'Arc servers with pending critical or security updates'; Column = 'LastAssessed' }
        @{ Path = 'workbooks\arc-compliance.workbook.json'; Tile = 'Privileged activity by server'; Column = 'LastActivity' }
        @{ Path = 'workbooks\arc-governance.workbook.json'; Tile = 'Guest configuration results'; Column = 'LastChecked' }
    )
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    function Read-Queries($RelativePath) {
        $book = Get-Content -LiteralPath (Join-Path $repo $RelativePath) -Raw | ConvertFrom-Json -Depth 100
        @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 3 })
    }
    function Read-Parameters($RelativePath) {
        $book = Get-Content -LiteralPath (Join-Path $repo $RelativePath) -Raw | ConvertFrom-Json -Depth 100
        @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
    }
    function Get-Formatter($Query) {
        foreach ($formatter in @($Query.content.gridSettings.formatters)) { if ($formatter) { $formatter } }
    }
}

Describe 'Rebuilt workbooks lay out cleanly in the portal' {
    It '<Name>: sizes every custom-width grid column so its header is not cut off' -ForEach $books {
        foreach ($query in Read-Queries $Path) {
            $labels = @{}
            foreach ($setting in @($query.content.gridSettings.labelSettings)) { if ($setting) { $labels[$setting.columnId] = $setting.label } }
            foreach ($formatter in Get-Formatter $query) {
                $width = $formatter.formatOptions.customColumnWidthSetting
                if ($width -and $width -match '^(\d+)ch$') {
                    $label = if ($labels.ContainsKey($formatter.columnMatch)) { $labels[$formatter.columnMatch] } else { $formatter.columnMatch }
                    ($label.Length + 5) | Should -BeLessOrEqual ([int]$Matches[1]) -Because "$($query.content.title): header '$label' is cut off at $width"
                }
            }
        }
    }

    It '<Name>: keeps parameter labels short enough not to be cut off' -ForEach $books {
        foreach ($parameter in Read-Parameters $Path) {
            $parameter.label.Length | Should -BeLessOrEqual 20 -Because $parameter.label
        }
    }

    It '<Name>: prints percentage bars as percentages on a fixed 0 to 100 red-to-green scale' -ForEach $books {
        foreach ($query in Read-Queries $Path) {
            foreach ($formatter in Get-Formatter $query | Where-Object { $_.formatter -eq 8 -and $_.formatOptions.palette -in 'redGreen', 'greenRed' }) {
                $formatter.formatOptions.palette | Should -Be 'redGreen' -Because $query.content.title
                $formatter.formatOptions.min | Should -Be 0 -Because $query.content.title
                $formatter.formatOptions.max | Should -Be 100 -Because $query.content.title
                $formatter.numberFormat.unit | Should -Be 1 -Because "$($query.content.title): a bar without a number format prints 7.100"
                $formatter.numberFormat.options.maximumFractionDigits | Should -Be 1 -Because $query.content.title
            }
        }
    }

    It '<Name>: shows every date/time column in the viewer''s local time, wide enough to read' -ForEach $books {
        foreach ($query in Read-Queries $Path) {
            foreach ($formatter in Get-Formatter $query | Where-Object { $_.formatter -eq 6 }) {
                $formatter.dateFormat.PSObject.Properties.Name | Should -Contain 'showUtcTime' -Because $query.content.title
                $formatter.dateFormat.showUtcTime | Should -BeNullOrEmpty -Because "$($query.content.title): null means local time"
                $formatter.dateFormat.formatName | Should -Be 'shortDateTimeNoMsPattern'
                [int]($formatter.formatOptions.customColumnWidthSetting -replace 'ch$', '') | Should -BeGreaterOrEqual 23 -Because $query.content.title
            }
        }
    }

    It 'renders <Column> in <Tile> with the date/time renderer, not as a raw ISO string' -ForEach $dateColumns {
        $query = Read-Queries $Path | Where-Object { $_.content.title -eq $Tile }
        $query | Should -Not -BeNullOrEmpty
        $formatter = Get-Formatter $query | Where-Object { $_.columnMatch -eq $Column }
        $formatter | Should -Not -BeNullOrEmpty
        $formatter.formatter | Should -Be 6
    }

    It '<Name>: lets small grids fit their rows (size 3, capped at 25 rows) and keeps long lists at the fixed size' -ForEach $books {
        $longLists = 'Most widely installed software', 'Software by publisher', 'Recent software changes'
        foreach ($query in Read-Queries $Path | Where-Object { $_.content.visualization -eq 'table' }) {
            $title = $query.content.title
            if ($title -in $longLists) {
                $query.content.size | Should -Be 0 -Because "$title is a long list and keeps the fixed height so the page does not balloon"
                continue
            }
            $query.content.size | Should -Be 3 -Because "${title}: a Small grid reserves about 330 px even with one row, which leaves a blank band"
            $limit = $query.content.gridSettings.rowLimit
            $take = [regex]::Matches($query.content.query, '\|\s*take\s+(\d+)') | Select-Object -Last 1
            $capped = ($null -ne $limit -and $limit -le 25) -or ($null -ne $take -and [int]$take.Groups[1].Value -le 25)
            $capped | Should -BeTrue -Because "$title fits its rows, so it must be capped at 25 rows by a take or a rowLimit"
        }
    }

    It '<Name>: names the category column of any grouped bar chart' -ForEach $books {
        foreach ($query in Read-Queries $Path | Where-Object { $_.content.visualization -eq 'barchart' -and $_.content.chartSettings.group }) {
            $query.content.chartSettings.xAxis | Should -Not -BeNullOrEmpty -Because $query.content.title
            @($query.content.chartSettings.yAxis).Count | Should -Be 1 -Because $query.content.title
        }
    }

    It '<Name>: prints any percentage chart as percentages on a fixed 0 to 100 axis' -ForEach $books {
        foreach ($query in Read-Queries $Path | Where-Object { $_.content.visualization -in 'barchart', 'categoricalbar' -and (@($_.content.chartSettings.yAxis) -match 'Percent') }) {
            $axis = $query.content.chartSettings.ySettings
            $axis.numberFormatSettings.unit | Should -Be 1 -Because "$($query.content.title): a percentage axis without a unit shows bare numbers such as 55.6"
            $axis.min | Should -Be 0 -Because $query.content.title
            $axis.max | Should -Be 100 -Because $query.content.title
        }
    }
}
