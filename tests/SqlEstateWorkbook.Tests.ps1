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

    It 'ships no workspace scope of its own: Phase 11 pins every Log Analytics tile to the deployment workspace at publish' {
        $la.Count | Should -BeGreaterThan 0
        foreach ($item in $la) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'crossComponentResources' -Because $item.name }
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
        $grid.labelSettings | Where-Object columnId -eq 'Defender' | ForEach-Object { $_.label | Should -Be 'Defender (reported)' }
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

    It 'keeps the version and licence charts that understand Arc SQL text values' {
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

    It 'follows the time range on every Log Analytics tile and never on Resource Graph tiles' {
        foreach ($item in $la) { $item.content.timeContextFromParameter | Should -Be 'TimeRange' -Because $item.name }
        foreach ($item in $arg) { $item.content.PSObject.Properties.Name | Should -Not -Contain 'timeContextFromParameter' -Because $item.name }
    }
}

Describe 'SQL Estate Dashboard tiles stay readable and mean what they say' {
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

    It 'uses a numeric-looking recovery column with a green-to-red scale where slow recovery is bad' {
        $grid = ($la | Where-Object name -eq 'workload-incidents').content.gridSettings
        $recovery = $grid.formatters | Where-Object columnMatch -eq 'RecoveredAfterSec'
        $recovery.formatter | Should -Be 8
        $recovery.formatOptions.palette | Should -Be 'greenRed'
    }
}
