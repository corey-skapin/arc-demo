BeforeAll {
    $repo = Split-Path $PSScriptRoot
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    $path = Join-Path $repo 'workbooks\arc-governance.workbook.json'
    $raw = Get-Content -LiteralPath $path -Raw
    $book = $raw | ConvertFrom-Json -Depth 100
    $queries = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 3 })
    $texts = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 1 })
    $parameters = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
    $argTables = 'resources', 'policyresources', 'securityresources', 'patchassessmentresources', 'guestconfigurationresources'
}

Describe 'Arc governance and compliance workbook (rebuilt, repo-native, experimental)' {
    It 'is a valid Notebook/1.0 workbook with query items' {
        $book.version | Should -Be 'Notebook/1.0'
        $queries.Count | Should -BeGreaterThan 7
    }

    It 'has no workspace or subscription picker and every parameter has a stored default' {
        @($parameters | Where-Object { $_.type -in 5, 6 }).Count | Should -Be 0
        foreach ($parameter in $parameters) { $parameter.value | Should -Not -BeNullOrEmpty -Because $parameter.name }
    }

    It 'is all Resource Graph over every subscription, so there is no Log Analytics scope to resolve' {
        $raw | Should -Not -Match '__WORKSPACE__'
        foreach ($item in $queries) {
            $item.content.queryType | Should -Be 1 -Because $item.content.title
            @($item.content.crossComponentResources) | Should -Be @('value::all') -Because $item.content.title
        }
    }

    It 'gives every tile a specific no-data message' {
        foreach ($item in $queries) {
            $item.content.noDataMessage | Should -Not -BeNullOrEmpty -Because $item.content.title
            $item.content.noDataMessage.Length | Should -BeGreaterThan 30 -Because $item.content.title
            $item.content.noDataMessage | Should -Not -Match '^No results\.?$'
        }
    }

    It 'keeps tile labels and literal notes short enough not to truncate and values numeric' {
        $tiles = @($queries | Where-Object { $_.content.visualization -eq 'tiles' })
        $tiles.Count | Should -BeGreaterThan 4
        foreach ($tile in $tiles) {
            $query = $tile.content.query
            $query | Should -Match 'Value = (toint|todouble|tolong)\('
            foreach ($match in [regex]::Matches($query, "'Label', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because $match.Groups[1].Value }
            foreach ($match in [regex]::Matches($query, "'Note', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 40 -Because $match.Groups[1].Value }
        }
    }

    It 'scales percentage tiles on a fixed 0 to 100 red-to-green range, never green at zero' {
        foreach ($title in 'Policy compliance', 'Tag coverage') {
            $tile = $queries | Where-Object { $_.content.title -eq $title }
            $tile.content.tileSettings.leftContent.formatOptions.palette | Should -Be 'redGreen' -Because $title
            $tile.content.tileSettings.leftContent.formatOptions.min | Should -Be 0 -Because $title
            $tile.content.tileSettings.leftContent.formatOptions.max | Should -Be 100 -Because $title
        }
        $raw | Should -Not -Match 'greenRed'
    }

    It 'compares all resources with the Arc servers using only checks that returned a result' {
        $query = ($queries | Where-Object { $_.content.title -eq 'Policy compliance' }).content.query
        $query | Should -Match "'All resources'"
        $query | Should -Match "'Arc servers'"
        $query | Should -Match "AllPass \+ AllFail"
        $query | Should -Match 'microsoft\.hybridcompute/machines'
    }

    It 'only treats resource-group-scoped resource ids as belonging to a resource group' {
        foreach ($title in 'Policy results', 'Compliance by resource group') {
            ($queries | Where-Object { $_.content.title -eq $title }).content.query | Should -Match "== 'resourcegroups'"
        }
    }

    It 'never joins more than two Resource Graph tables or mixes security and patch tables in one query' {
        foreach ($item in $queries) {
            $query = $item.content.query
            $used = @($argTables | Where-Object { $query -match "(?m)(^|[\s(|])$_\b" })
            $used.Count | Should -BeLessOrEqual 2 -Because "$($item.content.title) uses $($used -join ', ')"
            ($used -contains 'securityresources' -and $used -contains 'patchassessmentresources') | Should -BeFalse -Because $item.content.title
        }
    }

    It 'avoids a multi-key top operator' {
        foreach ($item in $queries) { $item.content.query | Should -Not -Match '\|\s*top\s+\d+\s+by\s+[^|\r\n]*,' -Because $item.content.title }
    }

    It 'presents no invented figures, business-case claims or hospital framing as fact' {
        foreach ($text in $texts) {
            $text.content.json | Should -Not -Match '\$\s?\d' -Because $text.name
            $text.content.json | Should -Not -Match '(?i)per year|annually|ROI|savings|procurement|reclaim|million|shareholder|board-ready|hospital|executive' -Because $text.name
        }
        $raw | Should -Not -Match '(?i)hospital'
    }

    It 'explains the vulnerability view as not applicable instead of showing empty tiles' {
        $note = ($texts | Where-Object { $_.content.json -match 'Vulnerability findings' }).content.json
        $note | Should -Match 'Not applicable in this lab'
        $note | Should -Match 'no vulnerability findings for the Arc machines'
        $raw | Should -Not -Match 'Machines should have vulnerability findings resolved'
    }

    It 'shows policy assignments in a full-width table so the names are not cut off' {
        $assignments = $queries | Where-Object { $_.content.title -eq 'Compliance by policy assignment' }
        $assignments.PSObject.Properties.Name | Should -Not -Contain 'customWidth'
        $assignments.content.visualization | Should -Be 'table'
    }

    It 'carries no real subscription path, no replacement character and keeps the upstream attribution' {
        $raw | Should -Not -Match '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $raw.Contains([string][char]0xFFFD) | Should -BeFalse
        $raw | Should -Match 'Nic Seilaz'
        $raw | Should -Match 'MIT'
    }

    It 'is the file the deployment publishes for Arc - Governance & Compliance (experimental)' {
        $deploy = Get-Content -LiteralPath (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -Raw
        $deploy | Should -Match 'arc-governance\.workbook\.json'
        $deploy | Should -Not -Match 'file = ''GovernanceComplianceWorkbook_Experiment\.json'''
    }
}
