BeforeAll {
    $repo = Split-Path $PSScriptRoot
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    $path = Join-Path $repo 'workbooks\arc-compliance.workbook.json'
    $raw = Get-Content -LiteralPath $path -Raw
    $book = $raw | ConvertFrom-Json -Depth 100
    $queries = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 3 })
    $texts = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 1 })
    $parameters = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters })
    $argTables = 'resources', 'policyresources', 'securityresources', 'patchassessmentresources'
}

Describe 'Arc compliance, security and governance workbook (rebuilt, repo-native)' {
    It 'is a valid Notebook/1.0 workbook with query items' {
        $book.version | Should -Be 'Notebook/1.0'
        $queries.Count | Should -BeGreaterThan 12
    }

    It 'has no workspace or subscription picker and every parameter has a stored default' {
        @($parameters | Where-Object { $_.type -in 5, 6 }).Count | Should -Be 0
        foreach ($parameter in $parameters) { $parameter.value | Should -Not -BeNullOrEmpty -Because $parameter.name }
    }

    It 'leaves the Log Analytics scope to Phase 11, ties those tiles to the time range and scopes Resource Graph tiles to all subscriptions' {
        $raw | Should -Not -Match '__WORKSPACE__'
        @($book.fallbackResourceIds).Count | Should -Be 0
        foreach ($item in $queries) {
            if ($item.content.queryType -eq 0) {
                @($item.content.crossComponentResources).Count | Should -Be 0 -Because $item.content.title
                $item.content.timeContextFromParameter | Should -Be 'TimeRange' -Because $item.content.title
            }
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

    It 'keeps tile labels and literal notes short enough not to truncate and values numeric' {
        $tiles = @($queries | Where-Object { $_.content.visualization -eq 'tiles' })
        $tiles.Count | Should -BeGreaterThan 5
        foreach ($tile in $tiles) {
            $query = $tile.content.query
            $query | Should -Match 'Value = (toint|todouble|tolong)\('
            foreach ($match in [regex]::Matches($query, "'Label', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 18 -Because $match.Groups[1].Value }
            foreach ($match in [regex]::Matches($query, "'Note', '([^']+)'")) { $match.Groups[1].Value.Length | Should -BeLessOrEqual 40 -Because $match.Groups[1].Value }
        }
    }

    It 'scales the posture percentages on a red-to-green palette, never green at zero' {
        foreach ($title in 'Policy and secure score', 'Patching and Defender agent') {
            $tile = $queries | Where-Object { $_.content.title -eq $title }
            $tile.content.tileSettings.leftContent.formatOptions.palette | Should -Be 'redGreen' -Because $title
            $tile.content.tileSettings.leftContent.numberFormat.unit | Should -Be 1 -Because $title
        }
        foreach ($item in $queries) { $raw | Should -Not -Match 'greenRed' }
    }

    It 'shows the four posture scores from real policy, Defender and Update Manager data' {
        $policy = ($queries | Where-Object { $_.content.title -eq 'Policy and secure score' }).content.query
        $policy | Should -Match 'policystates'
        $policy | Should -Match 'securescores'
        $policy | Should -Match "'Policy compliance'"
        $patch = ($queries | Where-Object { $_.content.title -eq 'Patching and Defender agent' }).content.query
        $patch | Should -Match 'patchassessmentresults'
        $patch | Should -Match "'Fully patched'"
        $patch | Should -Match "'Defender agent'"
    }

    It 'reads patch posture from Update Manager and never calls a failed or unassessed server fully patched' {
        $raw | Should -Not -Match '(?i)simplified approach'
        foreach ($title in 'Patch status', 'Arc servers with pending critical or security updates') {
            $query = ($queries | Where-Object { $_.content.title -eq $title }).content.query
            $query | Should -Match 'patchassessmentresults'
            $query | Should -Match "isempty\(AssessmentStatus\), 'Not assessed'"
            $query | Should -Match "AssessmentStatus =~ 'Succeeded', 'Fully patched'"
            $query | Should -Match "'Assessment failed'\s*\)"
        }
    }

    It 'never joins more than two Resource Graph tables or mixes security and patch tables in one query' {
        foreach ($item in @($queries | Where-Object { $_.content.queryType -eq 1 })) {
            $query = $item.content.query
            $used = @($argTables | Where-Object { $query -match "(?m)(^|[\s(|])$_\b" })
            $used.Count | Should -BeLessOrEqual 2 -Because "$($item.content.title) uses $($used -join ', ')"
            ($used -contains 'securityresources' -and $used -contains 'patchassessmentresources') | Should -BeFalse -Because $item.content.title
        }
    }

    It 'avoids a multi-key top operator' {
        foreach ($item in $queries) { $item.content.query | Should -Not -Match '\|\s*top\s+\d+\s+by\s+[^|\r\n]*,' -Because $item.content.title }
    }

    It 'presents no invented figures as fact' {
        foreach ($text in $texts) {
            $text.content.json | Should -Not -Match '\$\s?\d' -Because $text.name
            $text.content.json | Should -Not -Match '(?i)per year|annually|ROI|savings|procurement|reclaim' -Because $text.name
        }
    }

    It 'carries no real subscription path, no replacement character and keeps the upstream attribution' {
        $raw | Should -Not -Match '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $raw.Contains([string][char]0xFFFD) | Should -BeFalse
        $raw | Should -Match 'Nic Seilaz'
        $raw | Should -Match 'MIT'
    }

    It 'is the file the deployment publishes for Arc - Compliance, Security & Governance' {
        $deploy = Get-Content -LiteralPath (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -Raw
        $deploy | Should -Match 'arc-compliance\.workbook\.json'
        $deploy | Should -Not -Match 'file = ''Arc_Compliance_Security_Governance_example\.json'''
    }
}
