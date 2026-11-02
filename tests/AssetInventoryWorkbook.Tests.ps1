BeforeAll {
    $repo = Split-Path $PSScriptRoot
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    $path = Join-Path $repo 'workbooks\arc-asset-inventory.workbook.json'
    $raw = Get-Content -LiteralPath $path -Raw
    $book = $raw | ConvertFrom-Json -Depth 100
    $queries = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 3 })
    $texts = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 1 })
    $parameters = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
}

Describe 'Arc asset inventory workbook (rebuilt, repo-native)' {
    It 'is a valid Notebook/1.0 workbook with query items' {
        $book.version | Should -Be 'Notebook/1.0'
        $queries.Count | Should -BeGreaterThan 10
    }

    It 'has no workspace or subscription picker and every parameter has a stored default' {
        @($parameters | Where-Object { $_.type -in 5, 6 }).Count | Should -Be 0
        foreach ($parameter in $parameters) { $parameter.value | Should -Not -BeNullOrEmpty -Because $parameter.name }
    }

    It 'leaves the Log Analytics scope to Phase 11 and scopes Resource Graph tiles to all subscriptions' {
        $raw | Should -Not -Match '__WORKSPACE__'
        @($book.fallbackResourceIds).Count | Should -Be 0
        foreach ($item in $queries) {
            if ($item.content.queryType -eq 0) { @($item.content.crossComponentResources).Count | Should -Be 0 -Because $item.content.title }
            else { @($item.content.crossComponentResources) | Should -Be @('value::all') -Because $item.content.title }
        }
    }

    It 'gives every tile a specific no-data message' {
        foreach ($item in $queries) {
            $item.content.noDataMessage | Should -Not -BeNullOrEmpty -Because $item.content.title
            $item.content.noDataMessage.Length | Should -BeGreaterThan 30 -Because $item.content.title
            $item.content.noDataMessage | Should -Not -Match '^No results\.?$'
        }
    }

    It 'uses a flat JSON array for the dropdown and defaults it to All' {
        $filter = $parameters | Where-Object name -eq 'OsFilter'
        $options = @($filter.jsonData | ConvertFrom-Json -Depth 5)
        $options.Count | Should -BeGreaterThan 1
        foreach ($option in $options) { $option.PSObject.Properties.Name | Should -Contain 'value' }
        $filter.value | Should -Be '*'
        @($options.value) | Should -Contain '*'
    }

    It 'presents no invented figures as fact' {
        foreach ($text in $texts) {
            $text.content.json | Should -Not -Match '\$\s?\d' -Because $text.name
            $text.content.json | Should -Not -Match '(?i)per year|annually|ROI|savings|procurement|reclaim' -Because $text.name
        }
    }

    It 'keeps tile labels and literal notes short enough not to truncate and values numeric' {
        $tiles = @($queries | Where-Object { $_.content.visualization -eq 'tiles' })
        $tiles.Count | Should -BeGreaterThan 3
        foreach ($tile in $tiles) {
            $query = $tile.content.query
            $query | Should -Match 'Value = (toint|todouble)\('
            foreach ($match in [regex]::Matches($query, "'Label', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because $match.Groups[1].Value }
            foreach ($match in [regex]::Matches($query, "'Note', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 40 -Because $match.Groups[1].Value }
        }
    }

    It 'scales the tag coverage tiles on a red-to-green palette, never green at zero' {
        $tag = $queries | Where-Object { $_.content.title -eq 'Tag coverage' }
        $tag.content.tileSettings.leftContent.formatOptions.palette | Should -Be 'redGreen'
    }

    It 'accepts the lab tag names and avoids a multi-key top operator' {
        $tagQueries = @($queries | Where-Object { $_.content.query -match 'tags\.' })
        $tagQueries.Count | Should -BeGreaterThan 0
        foreach ($item in $tagQueries) { $item.content.query | Should -MatchExactly 'tags\.costcenter' }
        foreach ($item in $queries) { $item.content.query | Should -Not -Match '\|\s*top\s+\d+\s+by\s+[^|\r\n]*,' -Because $item.content.title }
    }

    It 'carries no real subscription path, no replacement character and keeps the upstream attribution' {
        $raw | Should -Not -Match '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $raw.Contains([string][char]0xFFFD) | Should -BeFalse
        $raw | Should -Match 'Nic Seilaz'
        $raw | Should -Match 'MIT'
    }

    It 'is the file the deployment publishes for Arc - Asset Inventory' {
        $deploy = Get-Content -LiteralPath (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -Raw
        $deploy | Should -Match 'arc-asset-inventory\.workbook\.json'
        $deploy | Should -Not -Match 'file = ''Asset_Inventory_Workbook_Example\.json'''
    }
}
