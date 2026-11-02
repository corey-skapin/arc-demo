BeforeDiscovery {
    $cases = @(
        @{ Name = 'Estate Overview'; Path = 'workbooks\arc-demo-overview.workbook.json' }
        @{ Name = 'Asset Inventory'; Path = 'workbooks\nseilaz\Asset_Inventory_Workbook_Example.json' }
        @{ Name = 'Compliance, Security & Governance'; Path = 'workbooks\nseilaz\Arc_Compliance_Security_Governance_example.json' }
        @{ Name = 'Governance & Compliance (experimental)'; Path = 'workbooks\nseilaz\GovernanceComplianceWorkbook_Experiment.json' }
        @{ Name = 'Machine Intelligence Center'; Path = 'workbooks\nseilaz\ArcMachineIntelligenceCenter.json' }
        @{ Name = 'SQL Estate Dashboard'; Path = 'workbooks\nseilaz\SQL_Estate_Dashboard.json' }
    )
    $pickerCases = @(
        @{ Name = 'Asset Inventory'; Path = 'workbooks\nseilaz\Asset_Inventory_Workbook_Example.json' }
        @{ Name = 'Compliance, Security & Governance'; Path = 'workbooks\nseilaz\Arc_Compliance_Security_Governance_example.json' }
        @{ Name = 'Governance & Compliance (experimental)'; Path = 'workbooks\nseilaz\GovernanceComplianceWorkbook_Experiment.json' }
        @{ Name = 'SQL Estate Dashboard'; Path = 'workbooks\nseilaz\SQL_Estate_Dashboard.json' }
    )
    $tagCases = @(
        @{ Name = 'Asset Inventory'; Path = 'workbooks\nseilaz\Asset_Inventory_Workbook_Example.json' }
        @{ Name = 'Governance & Compliance (experimental)'; Path = 'workbooks\nseilaz\GovernanceComplianceWorkbook_Experiment.json' }
    )
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot
    function Read-Workbook([string]$RelativePath) {
        Get-Content -LiteralPath (Join-Path $repo $RelativePath) -Raw | ConvertFrom-Json -Depth 100
    }
    function Get-WorkbookItem($Items) {
        foreach ($item in @($Items)) {
            $item
            if ($item.content.items) { Get-WorkbookItem $item.content.items }
        }
    }
    function Get-WorkbookQuery($Book) {
        @(Get-WorkbookItem $Book.items | Where-Object { $_.type -eq 3 -and $_.content.query })
    }
}

Describe 'Original published workbooks stay valid' {
    It '<Name> is a Notebook/1.0 workbook whose query items are all non-empty' -ForEach $cases {
        $book = Read-Workbook $Path
        $book.version | Should -Be 'Notebook/1.0'
        $queries = Get-WorkbookQuery $book
        $queries.Count | Should -BeGreaterThan 0
        foreach ($item in $queries) { [string]::IsNullOrWhiteSpace($item.content.query) | Should -BeFalse }
    }

    It '<Name> has no replacement characters in item titles' -ForEach $cases {
        $book = Read-Workbook $Path
        $replacement = [string][char]0xFFFD
        foreach ($item in @(Get-WorkbookItem $book.items | Where-Object { $_.content.title })) {
            $item.content.title.Contains($replacement) | Should -BeFalse -Because $item.content.title
        }
    }

    It 'ships no real subscription path in <Name>' -ForEach $cases {
        $raw = Get-Content -LiteralPath (Join-Path $repo $Path) -Raw
        $raw | Should -Not -Match '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    }
}

Describe 'Estate Overview keeps the guided section 1 tiles and honest supporting tiles' {
    BeforeAll {
        $byTitle = @{}
        foreach ($item in Get-WorkbookQuery (Read-Workbook 'workbooks\arc-demo-overview.workbook.json')) { $byTitle[$item.content.title] = $item.content.query }
    }

    It 'still has the three tiles the Arc presenter guide names' {
        $byTitle.Keys | Should -Contain 'Estate connectivity (last 15m)'
        $byTitle.Keys | Should -Contain 'Hosts beating over time (24h)'
        $byTitle.Keys | Should -Contain 'Per-host CPU utilisation (24h)'
    }

    It 'shows parked periods as zero hosts beating instead of interpolating across the gap' {
        $byTitle['Hosts beating over time (24h)'] | Should -Match 'make-series HostsBeating = dcount\(Computer\) default = 0 on TimeGenerated from bin\(ago\(24h\), 15m\) to now\(\) step 15m'
    }

    It 'ranks the Azure Monitor Agent severity name error as an error' {
        $byTitle['Linux syslog activity (24h)'] | Should -Match "'crit', 'err', 'error'"
    }

    It 'leaves level-0 Security audit rows out of the critical and error tile' {
        $byTitle['Critical & Error events (Windows, 24h)'] | Should -Match 'EventLevel in \(1, 2\)'
        $byTitle['Critical & Error events (Windows, 24h)'] | Should -Not -Match 'EventLevel <= 2'
    }

    It 'does not chart blank-type change twin rows' {
        $byTitle['Configuration changes (24h)'] | Should -Match 'isnotempty\(ConfigChangeType\)'
    }
}

Describe 'Compliance patch tiles use real Update Manager data' {
    BeforeAll {
        $book = Read-Workbook 'workbooks\nseilaz\Arc_Compliance_Security_Governance_example.json'
        $scorecard = (Get-WorkbookQuery $book | Where-Object { $_.content.query -match 'FullyPatchedPct' }).content.query
        $table = (Get-WorkbookQuery $book | Where-Object { $_.content.title -eq 'Arc servers with pending critical or security updates' }).content.query
    }

    It 'has both the scorecard and the table' {
        $scorecard | Should -Not -BeNullOrEmpty
        $table | Should -Not -BeNullOrEmpty
    }

    It 'reads Update Manager assessments, not a connection-state estimate' {
        foreach ($query in @($scorecard, $table)) {
            $query | Should -Match 'patchassessmentresources'
            $query | Should -Match 'microsoft\.hybridcompute/machines/patchassessmentresults'
            $query | Should -Not -Match 'HealthScore|EstimatedCritical|daysOffline'
        }
    }

    It 'classifies machines identically in the scorecard and the table' {
        $common = { param($query) ($query -split '\| summarize|\| where PatchState')[0] }
        (& $common $scorecard) | Should -Be (& $common $table)
    }

    It 'never reports a failed or unassessed machine as fully patched' {
        $scorecard | Should -Match "isempty\(AssessmentStatus\), 'Not assessed'"
        $scorecard | Should -Match "'Assessment failed'"
        $scorecard | Should -Match "FullyPatched = countif\(PatchState == 'Fully patched'\)"
        $table | Should -Match "PatchState != 'Fully patched'"
    }
}

Describe 'Gallery workbooks open populated' {
    It '<Name> subscription pickers default to all subscriptions' -ForEach $pickerCases {
        $book = Read-Workbook $Path
        $pickers = @(Get-WorkbookItem $book.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters } | Where-Object { $_.type -eq 6 })
        $pickers.Count | Should -BeGreaterThan 0
        foreach ($picker in $pickers) { @($picker.value) | Should -Contain 'value::all' -Because $picker.name }
    }

    It '<Name> tag queries also read the lab tag names costcenter, owner and env' -ForEach $tagCases {
        $queries = @(Get-WorkbookQuery (Read-Workbook $Path) | ForEach-Object { $_.content.query } | Where-Object { $_ -match 'tags[\.\[]' })
        $queries.Count | Should -BeGreaterThan 0
        foreach ($query in $queries) {
            if ($query -cmatch "tags(\.|\[')CostCentre") { $query | Should -MatchExactly "tags(\.|\[')costcenter" }
            if ($query -cmatch "tags(\.|\[')Owner") { $query | Should -MatchExactly "tags(\.|\[')owner" }
            if ($query -cmatch "tags(\.|\[')Environment") { $query | Should -MatchExactly "tags(\.|\[')env" }
        }
    }

    It 'Governance health tile projects the Compliant column its tile settings read' {
        $book = Read-Workbook 'workbooks\nseilaz\GovernanceComplianceWorkbook_Experiment.json'
        $tile = Get-WorkbookQuery $book | Where-Object { $_.content.title -like '*Governance Health Score' }
        @($tile).Count | Should -Be 1
        $tile.content.query | Should -Match 'project ComplianceRate, RiskScore, Total, Compliant, NonCompliant'
    }

    It 'SQL Estate Dashboard names text-form SQL versions and Free licences instead of Unknown' {
        $book = Read-Workbook 'workbooks\nseilaz\SQL_Estate_Dashboard.json'
        $version = Get-WorkbookQuery $book | Where-Object { $_.content.query -match 'versionMajor = case' }
        $license = Get-WorkbookQuery $book | Where-Object { $_.content.query -match 'licenseDisplay = case' }
        $version.content.query | Should -Match "version has '2022', 'SQL 2022'"
        $version.content.query | Should -Match "version has '2019', 'SQL 2019'"
        $license.content.query | Should -Match "licenseType =~ 'Free'"
    }
}
