BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\OperationalWorkbooks.psm1') -Force
    $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
    $workspaceId = "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture"
    $parentId = "$scope/providers/Microsoft.HybridCompute/machines/parent"
    $guestId = "$scope/providers/Microsoft.HybridCompute/machines/guest"
    $machines = @(@{ id = $parentId }, @{ id = $guestId })

    function Get-WorkbookItems($items) {
        foreach ($item in $items) { $item; if ($item.type -eq 12) { Get-WorkbookItems $item.content.items } }
    }
    function Get-Placeholders([string]$Text) {
        [regex]::Matches($Text, '\{([A-Za-z][A-Za-z0-9]*)(?::[A-Za-z]+)?\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    }
    function Get-JsonNodes($Node) {
        if ($Node -is [System.Collections.IList]) { foreach ($child in $Node) { Get-JsonNodes $child } }
        elseif ($Node -is [pscustomobject]) { $Node; foreach ($property in $Node.PSObject.Properties) { Get-JsonNodes $property.Value } }
    }
    # Every {placeholder} must be a workbook parameter visible at that point (global, exported by a selection, or in an enclosing group).
    function Test-WorkbookScoping($items, [string[]]$scopeNames) {
        $local = [System.Collections.Generic.List[string]]::new($scopeNames)
        foreach ($item in $items) {
            if ($item.type -eq 9) { foreach ($p in $item.content.parameters) { $local.Add($p.name) }; continue }
            if ($item.type -eq 11) { foreach ($l in $item.content.links) { if ($l.cellValue -notin $local) { $local.Add($l.cellValue) } }; continue }
            $visibility = $item.PSObject.Properties['conditionalVisibility']
            if ($visibility -and $visibility.Value.parameterName -notin $local) { "$($item.name): visibility parameter $($visibility.Value.parameterName) is undefined" }
            if ($item.type -eq 1) {
                foreach ($name in Get-Placeholders $item.content.json) { if ($name -notin $local) { "$($item.name): text placeholder $name is undefined" } }
            } elseif ($item.type -eq 3) {
                $content = $item.content
                if ($content.PSObject.Properties['exportParameterName']) { $local.Add([string]$content.exportParameterName) }
                foreach ($name in Get-Placeholders $content.query) {
                    if ($name -notin $local) { "$($item.name): query placeholder $name is undefined" }
                }
                if ($content.PSObject.Properties['chartSettings'] -and $content.chartSettings.PSObject.Properties['customThresholdLine']) {
                    foreach ($name in Get-Placeholders $content.chartSettings.customThresholdLine) { if ($name -notin $local) { "$($item.name): threshold line $name is undefined" } }
                }
            } elseif ($item.type -eq 12) {
                Test-WorkbookScoping $item.content.items @($local)
            }
        }
    }
}

Describe 'Scoped operational workbook rendering' {
    It 'renders valid exact-ID queries with single-workspace scopes for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $result = Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines
        $book = $result.SerializedData | ConvertFrom-Json -Depth 100
        $book.version | Should -Be 'Notebook/1.0'
        $result.SerializedData | Should -Not -Match '__(QUERY|OPTIONS|DEFAULT|SCOPE|PREPARED|ROSTER)'
        $result.SerializedData | Should -Match 'unclassified'
        $book.fallbackResourceIds | Should -Be @($workspaceId.ToLowerInvariant())
        $logItems = @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 0 })
        $logItems.Count | Should -BeGreaterThan 10
        foreach ($item in $logItems) {
            $item.content.crossComponentResources | Should -Be @($workspaceId.ToLowerInvariant())
            $item.content.timeContextFromParameter | Should -Be 'TimeRange'
            $item.content.query | Should -Match 'let AllMachines = print Data = dynamic\('
            if ($item.content.query -match 'let PerfRows = Perf') { $item.content.query | Should -Match 'ResourceId in \(Machines' }
            $item.content.query | Should -Not -Match 'ResourceId\s+(startswith|has|contains)\b'
            $item.content.query | Should -Not -Match 'default\s*=\s*0\b'
        }
        foreach ($item in @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 1 })) {
            $item.content.crossComponentResources | Should -Be @('/subscriptions/11111111-1111-1111-1111-111111111111')
            $item.content.query | Should -Match 'tolower\(id\) in \("/subscriptions/.*/machines/guest"'
        }
    }

    It 'declares every parameter a query, text, threshold line or visibility rule uses for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        @(Test-WorkbookScoping $book.items @('selectedTab')) | Should -BeNullOrEmpty
    }

    It 'renders every dropdown option list as a flat array of objects the portal can expand for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $dropdowns = @($book.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters } | Where-Object { $_.type -eq 2 -and $_.jsonData })
        $dropdowns.Count | Should -BeGreaterOrEqual 9
        foreach ($dropdown in $dropdowns) {
            # An array wrapped in a second array leaves the portal with one unusable option, so All cannot expand to anything.
            $dropdown.jsonData | Should -Match '^\[\{' -Because "$($dropdown.name) options must be a flat array of objects"
            $options = $dropdown.jsonData | ConvertFrom-Json -NoEnumerate
            @($options).Count | Should -BeGreaterThan 0
            foreach ($option in $options) {
                $option.value | Should -Not -BeNullOrEmpty
                $option.label | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'builds option lists as flat JSON arrays for zero, one and several values' {
        InModuleScope OperationalWorkbooks {
            Get-DemoOperationalOptions -Roster @() -Kind os | Should -BeExactly '[]'
            $linux = [pscustomobject]@{ os = 'Linux'; environment = 'demo'; application = 'app'; machine = 'a' }
            $windows = [pscustomobject]@{ os = 'Windows'; environment = 'demo'; application = 'sql'; machine = 'b' }
            Get-DemoOperationalOptions -Roster @($linux) -Kind environment | Should -BeExactly '[{"value":"demo","label":"demo"}]'
            Get-DemoOperationalOptions -Roster @($windows, $linux) -Kind os | Should -BeExactly '[{"value":"Linux","label":"Linux"},{"value":"Windows","label":"Windows"}]'
        }
    }

    It 'treats All as no filter in the three scope dropdowns for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        foreach ($name in 'OsFilter', 'EnvironmentFilter', 'ApplicationFilter') {
            $dropdown = @($book.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters } | Where-Object name -eq $name)[0]
            $dropdown.multiSelect | Should -BeTrue
            @($dropdown.value) | Should -Be @('value::all')
            $dropdown.defaultValue | Should -Be 'value::all'
            $dropdown.typeSettings.additionalResourceOptions | Should -Contain 'value::all'
            # Official All dropdowns set the special All value (empty: the filter lists then expand to nothing) and a time context.
            $dropdown.typeSettings.PSObject.Properties.Name | Should -Contain 'selectAllValue'
            [string]$dropdown.typeSettings.selectAllValue | Should -BeExactly ''
            $dropdown.timeContext.durationMs | Should -BeGreaterThan 0
        }
    }

    It 'guards every Log Analytics filter test against an empty list, the literal All marker and * for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $logQueries = @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 0 } | ForEach-Object { $_.content.query })
        $logQueries.Count | Should -BeGreaterThan 10
        foreach ($query in $logQueries) {
            foreach ($filter in 'Os', 'Environment', 'Application') {
                $query | Should -Match "let ${filter}Filter = dynamic\(\[\{${filter}Filter\}\]\);"
                $query | Should -Match "let ${filter}All = array_length\(${filter}Filter\) == 0 or set_has_element\(${filter}Filter, 'value::all'\) or set_has_element\(${filter}Filter, '\*'\);"
                $query | Should -Match "\(${filter}All or ${filter} in \(${filter}Filter\)\)"
            }
        }
    }

    It 'guards the Resource Graph filter tests the same way, inline because Resource Graph has no let, for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $argQueries = @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 -and $_.content.queryType -eq 1 } | ForEach-Object { $_.content.query })
        $argQueries.Count | Should -BeGreaterThan 0
        foreach ($query in $argQueries) {
            $query | Should -Not -Match '(?m)^\s*let\s'
            foreach ($filter in 'Os', 'Environment', 'Application') {
                $uses = [regex]::Matches($query, "\{${filter}Filter\}").Count
                $inline = [regex]::Matches($query, "dynamic\(\[\{${filter}Filter\}\]\)").Count
                $uses | Should -BeGreaterThan 0
                $uses | Should -Be $inline -Because "$filter placeholders must only appear inside an inline dynamic list, never in a bare in () that an empty value would break"
                $query | Should -Match "array_length\(dynamic\(\[\{${filter}Filter\}\]\)\) == 0"
                $query | Should -Match "set_has_element\(dynamic\(\[\{${filter}Filter\}\]\), 'value::all'\)"
                $query | Should -Match "set_has_element\(dynamic\(\[\{${filter}Filter\}\]\), '\*'\)"
            }
        }
    }

    It 'expands every way of selecting All into a valid filter list' -ForEach @(
        @{ Form = 'an empty string'; Value = ''; Expected = 'dynamic\(\[\]\)' }
        @{ Form = 'the literal All marker'; Value = "'value::all'"; Expected = "dynamic\(\['value::all'\]\)" }
        @{ Form = 'a star'; Value = "'*'"; Expected = "dynamic\(\['\*'\]\)" }
    ) {
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $machines)
        $query = Expand-DemoOperationalQuery -Query (Get-DemoOperationalQuery -Name 'cap-scope' -Roster $roster) -Roster $roster `
            -Parameters @{ OsFilter = $Value; EnvironmentFilter = $Value; ApplicationFilter = $Value }
        foreach ($filter in 'Os', 'Environment', 'Application') { $query | Should -Match "let ${filter}Filter = $Expected;" }
        $query | Should -Not -Match '\{[A-Za-z]+Filter\}'
    }

    It 'labels the thresholds illustrative and exposes them as editable parameters for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $names = @($book.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters.name })
        foreach ($name in 'TimeRange', 'OsFilter', 'EnvironmentFilter', 'ApplicationFilter', 'CpuHigh', 'SustainedMinutes', 'MemHigh', 'DiskLow', 'LowCpuP95', 'MinObservedHours') {
            $names | Should -Contain $name
        }
        (($book.items | Where-Object name -eq 'thresholds-label').content.json) | Should -Match 'Illustrative thresholds.*not an approved service objective'
        # Three observed hours keeps an on-demand lab classifiable within hours of waking; the label must say it is illustrative.
        $evidence = @($book.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters } | Where-Object name -eq 'MinObservedHours')[0]
        $evidence.value | Should -Be '3'
        @($evidence.jsonData | ConvertFrom-Json | ForEach-Object value) | Should -Contain '3'
        (($book.items | Where-Object name -eq 'thresholds-label').content.json) | Should -Match 'Evidence needs.*defaults to 3 observed hours.*production review would normally ask for far more'
    }

    It 'uses the same shared evidence logic in both workbooks so identical scope gives identical metrics' {
        $series = (Get-Content (Join-Path $repo 'workbooks\queries\operational-series.kql') -Raw).Trim()
        $hosts = (Get-Content (Join-Path $repo 'workbooks\queries\operational-hosts.kql') -Raw).Trim()
        foreach ($purpose in 'capacity', 'optimisation') {
            $book = (Get-DemoOperationalWorkbook -Purpose $purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
            $queries = @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 -and $_.content.query -match 'let Hosts = ' } | ForEach-Object { $_.content.query })
            $queries.Count | Should -BeGreaterThan 3
            foreach ($query in $queries) {
                $query.Contains($series) | Should -BeTrue
                $query.Contains($hosts) | Should -BeTrue
            }
        }
    }

    It 'shares detail queries between both workbooks' {
        $capacity = (Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $optimisation = (Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        foreach ($name in 'detail-cpu-p95', 'detail-cpu-peak', 'detail-mem-pct', 'detail-disk', 'detail-evidence') {
            $one = (Get-WorkbookItems $capacity.items | Where-Object name -eq $name).content.query
            $two = (Get-WorkbookItems $optimisation.items | Where-Object name -eq $name).content.query
            $one | Should -Not -BeNullOrEmpty
            $one | Should -BeExactly $two
        }
    }

    It 'has stable per-workspace/purpose names, not random duplicates on retry' {
        $one = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines
        $two = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId.ToLowerInvariant() -Machines $machines
        $other = Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines
        $one.Name | Should -Be $two.Name
        $one.Name | Should -Not -Be $other.Name
    }

    It 'renders a separate, clearly marked draft that never shares the published identity' {
        foreach ($purpose in 'capacity', 'optimisation') {
            $published = Get-DemoOperationalWorkbook -Purpose $purpose -WorkspaceResourceId $workspaceId -Machines $machines
            $draft = Get-DemoOperationalWorkbook -Purpose $purpose -WorkspaceResourceId $workspaceId -Machines $machines -Draft
            $draft.Name | Should -Not -Be $published.Name
            $draft.ResourceId | Should -Not -Be $published.ResourceId
            $draft.DisplayName | Should -Be "$($published.DisplayName) (draft)"
            $draft.Draft | Should -BeTrue
            $published.Draft | Should -BeFalse
            ($draft.SerializedData | ConvertFrom-Json -Depth 100).items.name | Should -Contain 'draft-banner'
            ($published.SerializedData | ConvertFrom-Json -Depth 100).items.name | Should -Not -Contain 'draft-banner'
            $published.SerializedData | Should -Not -Match 'DRAFT for review'
        }
    }

    It 'rejects empty/foreign/duplicate Arc rosters' {
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @() } | Should -Throw
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @(@{ id = "$scope/providers/Microsoft.Compute/virtualMachines/parent" }) } | Should -Throw '*Foreign*'
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines @($machines[0], $machines[0]) } | Should -Throw '*duplicate*'
    }

    It 'uses only documented icon names, colour names and palettes for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        # Grid icon names are documented in Learn (workbooks grid visualizations); colour and palette names are the ones the official sample workbooks use.
        $icons = @('cancelled', 'critical', 'disabled', 'error', 'failed', 'info', 'none', 'pending', 'stopped', 'question', 'success', 'unknown', 'warning', 'uninitialized',
            'resource', 'up', 'down', 'left', 'right', 'trendup', 'trenddown', '4', '3', '2', '1', 'Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4', 'Fired', 'Resolved',
            'Available', 'Unavailable', 'Degraded', 'Unknown', 'Blank')
        $colours = @('None', 'redBright', 'green', 'yellow', 'orange', 'lightBlue', 'gray', 'turquoise', 'red', 'blueDark', 'blue', 'grayBlue', 'magenta', 'greenDark',
            'purple', 'brown', 'yellowDark', 'amethyst', 'pink', 'orangeDark')
        $palettes = @('auto', 'none', 'blue', 'blueDark', 'green', 'greenRed', 'orange', 'red', 'redGreen', 'redBright', 'turquoise', 'yellow', 'gray', 'purple', 'pink', 'magenta')
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $formatters = @(Get-JsonNodes $book.items | Where-Object { $_.PSObject.Properties['formatter'] -and $_.PSObject.Properties['formatOptions'] })
        $formatters.Count | Should -BeGreaterThan 20
        $problems = foreach ($entry in $formatters) {
            $options = $entry.formatOptions
            if ($entry.formatter -eq 18) {
                $kind = if ($options.PSObject.Properties['thresholdsOptions']) { $options.thresholdsOptions } else { 'colors' }
                foreach ($rule in $options.thresholdsGrid) {
                    if ($kind -eq 'icons' -and $rule.representation -cnotin $icons) { "$($entry.columnMatch): icon '$($rule.representation)'" }
                    if ($kind -ne 'icons' -and $rule.representation -cnotin $colours) { "$($entry.columnMatch): colour '$($rule.representation)'" }
                }
            } elseif ($entry.formatter -in 8, 10, 12 -and $options.PSObject.Properties['palette'] -and $options.palette -cnotin $palettes) {
                "$($entry.columnMatch): palette '$($options.palette)'"
            }
        }
        @($problems) | Should -BeNullOrEmpty
    }

    It 'gives every query item a clear empty state, amber only where absence is itself a finding, for <Purpose>' -ForEach @(@{ Purpose = 'capacity' }, @{ Purpose = 'optimisation' }) {
        $book = (Get-DemoOperationalWorkbook -Purpose $Purpose -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $warningAllowed = @('cpu-p95', 'cpu-peak', 'detail-cpu-p95', 'detail-cpu-peak', 'arc-status', 'own-grid')
        $items = @(Get-WorkbookItems $book.items | Where-Object { $_.type -eq 3 })
        $items.Count | Should -BeGreaterThan 10
        $missing = @($items | Where-Object { -not $_.content.PSObject.Properties['noDataMessage'] } | ForEach-Object name)
        $missing | Should -BeNullOrEmpty
        foreach ($item in $items) {
            $item.content.noDataMessageStyle | Should -BeIn 3, 4, 5
            if ($item.content.noDataMessageStyle -eq 5) { $item.name | Should -BeIn $warningAllowed }
        }
    }

    It 'leads the capacity workbook with scope and evidence quality before the assessment tiles' {
        $book = (Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $names = @($book.items | ForEach-Object name)
        $names.IndexOf('scope-tiles') | Should -BeGreaterThan $names.IndexOf('thresholds')
        $names.IndexOf('scope-tiles') | Should -BeLessThan $names.IndexOf('overview-tiles')
        $scope = $book.items | Where-Object name -eq 'scope-tiles'
        $scope.content.visualization | Should -Be 'tiles'
        $scope.content.query | Should -Match 'datatable\(SortKey:long\)'
        $scope.content.query | Should -Match 'Reporting now'
        $scope.content.query | Should -Match 'Latest sample'
        $scope.content.query | Should -Match 'Adequate evidence'
        ($book.items | Where-Object name -eq 'overview-tiles').content.query | Should -Not -MatchExactly 'Machines in scope"'
        $scope.content.query | Should -MatchExactly 'Machines in scope"'
    }

    It 'links each workbook to its sibling, a draft to the draft and a published workbook to the published one' {
        $tenant = '44444444-4444-4444-4444-444444444444'
        foreach ($isDraft in $false, $true) {
            $capacity = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Draft:$isDraft -TenantId $tenant
            $optimisation = Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines -Draft:$isDraft -TenantId $tenant
            $other = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Draft:(-not $isDraft)
            $capacity.SerializedData | Should -Match ([regex]::Escape("https://portal.azure.com/#@$tenant/resource$($optimisation.ResourceId)/workbook"))
            $optimisation.SerializedData | Should -Match ([regex]::Escape("https://portal.azure.com/#@$tenant/resource$($capacity.ResourceId)/workbook"))
            $optimisation.SerializedData | Should -Not -Match ([regex]::Escape($other.Name))
        }
        $plain = Get-DemoOperationalWorkbookLink -Purpose capacity -WorkspaceResourceId $workspaceId
        $plain | Should -Match '^https://portal\.azure\.com/#resource/subscriptions/'
        $plain | Should -Not -Match '#@'
    }

    It 'keeps the sibling link a valid markdown target and rejects a malformed tenant' {
        $withParens = "$scope-(lab)/providers/Microsoft.OperationalInsights/workspaces/law-fixture"
        $link = Get-DemoOperationalWorkbookLink -Purpose optimisation -WorkspaceResourceId $withParens
        $link | Should -Not -Match '[()]'
        $link | Should -Match '%28lab%29'
        { Get-DemoOperationalWorkbookLink -Purpose capacity -WorkspaceResourceId $workspaceId -TenantId 'not-a-tenant' } | Should -Throw
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -TenantId '](javascript:alert(1))' } | Should -Throw
    }

    It 'bounds the roster so every composed query stays well inside the Log Analytics request limit' {
        $many = @(1..51 | ForEach-Object { @{ id = "$scope/providers/Microsoft.HybridCompute/machines/m$_" } })
        { Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $many } | Should -Throw '*1-50*'
        $largest = @(1..50 | ForEach-Object { @{ id = "$scope/providers/Microsoft.HybridCompute/machines/machine-$_"; tags = @{ env = 'production'; application = 'line-of-business'; owner = 'someone@example.test'; costcenter = 'cc-0001' } } })
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $largest)
        foreach ($name in 'cap-hosts', 'opt-candidates', 'opt-sched-heatmap', 'opt-detail-card') {
            (Get-DemoOperationalQuery -Name $name -Roster $roster).Length | Should -BeLessThan 64000
        }
    }

    It 'derives the deterministic identity from the workspace alone, with no Arc inventory' {
        $identity = Get-DemoOperationalWorkbookIdentity -Purpose capacity -WorkspaceResourceId $workspaceId
        $rendered = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines
        $identity.ResourceId | Should -Be $rendered.ResourceId
        $identity.DisplayName | Should -Be 'Capacity and headroom'
        (Get-DemoOperationalWorkbookIdentity -Purpose capacity -WorkspaceResourceId $workspaceId -Draft).DisplayName | Should -Be 'Capacity and headroom (draft)'
        { Get-DemoOperationalWorkbookIdentity -Purpose capacity -WorkspaceResourceId '/not/a/workspace' } | Should -Throw '*workspace*'
    }

    It 'requires explicit valid topology without guessing host names' {
        $topology = @(@{ resourceId = $parentId; layer = 'parent' }, @{ resourceId = $guestId; layer = 'guest'; parentResourceId = $parentId })
        $book = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology $topology
        ($book.Machines | Where-Object layer -eq 'guest').parentResourceId | Should -Be $parentId.ToLowerInvariant()
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology @($topology[1]) } | Should -Throw '*explicitly classified*'
        { Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology @(@{ resourceId = $guestId; layer = 'guest'; parentResourceId = $guestId }) } | Should -Throw '*different selected*'
    }

    It 'carries operating system and published tags without trusting braces in tag values' {
        $tagged = @(
            @{ id = $parentId; osType = 'windows'; tags = @{ env = 'Dev'; role = 'sql {x}'; owner = 'a'; costcenter = 'b' }; detectedProperties = @{ logicalCoreCount = '4'; totalPhysicalMemoryInGigabytes = '16' } }
            @{ id = $guestId; osType = 'linux'; tags = @{} }
        )
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $tagged)
        $parent = $roster | Where-Object machine -eq 'parent'
        $guest = $roster | Where-Object machine -eq 'guest'
        $parent.os | Should -Be 'Windows'
        $parent.environment | Should -Be 'Dev'
        $parent.application | Should -Be 'sql (x)'
        $parent.vcpu | Should -Be 4
        $parent.memoryGb | Should -Be 16
        $guest.os | Should -Be 'Linux'
        $guest.environment | Should -Be '(untagged)'
        $guest.application | Should -Be '(untagged)'
        ($roster | ConvertTo-Json -Compress) | Should -Not -Match '[{][A-Za-z]'
    }

    It 'derives the nested guest topology from the skin declaration without double counting' {
        $config = [pscustomobject]@{ ParentVmName = 'parent'; GuestVmName = 'guest-vm'; ArcMachineName = 'guest' }
        $topology = @(ConvertTo-DemoNestedTopology -NestedGuest $config -Machines $machines -WorkspaceResourceId $workspaceId)
        $topology.Count | Should -Be 2
        ($topology | Where-Object layer -eq 'parent').resourceId | Should -Be $parentId.ToLowerInvariant()
        ($topology | Where-Object layer -eq 'guest').parentResourceId | Should -Be $parentId.ToLowerInvariant()
        $book = Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Topology $topology
        @($book.Machines | Where-Object layer -in 'parent', 'guest').Count | Should -Be 2
        @(ConvertTo-DemoNestedTopology -NestedGuest $null -Machines $machines -WorkspaceResourceId $workspaceId).Count | Should -Be 0
    }

    It 'tolerates a nested guest or parent that is not an Arc machine yet' {
        $config = [pscustomobject]@{ ParentVmName = 'parent'; GuestVmName = 'guest-vm'; ArcMachineName = 'not-onboarded' }
        $result = @(ConvertTo-DemoNestedTopology -NestedGuest $config -Machines $machines -WorkspaceResourceId $workspaceId -WarningVariable warned -WarningAction SilentlyContinue)
        $result.Count | Should -Be 0
        "$warned" | Should -Match 'not present yet'
        $missingParent = [pscustomobject]@{ ParentVmName = 'nope'; GuestVmName = 'g'; ArcMachineName = 'guest' }
        @(ConvertTo-DemoNestedTopology -NestedGuest $missingParent -Machines $machines -WorkspaceResourceId $workspaceId -WarningVariable warnedParent -WarningAction SilentlyContinue).Count | Should -Be 0
        "$warnedParent" | Should -Match 'parent'
    }

    It 'still renders a disconnected or untelemetered guest as its own separate row' {
        $topology = @(@{ resourceId = $parentId; layer = 'parent' }, @{ resourceId = $guestId; layer = 'guest'; parentResourceId = $parentId })
        $book = Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines -Topology $topology
        $query = (Get-WorkbookItems ($book.SerializedData | ConvertFrom-Json -Depth 100).items | Where-Object name -eq 'candidates').content.query
        $query | Should -Match '"layer":"guest"'
        $query | Should -Match 'Layer != "guest"'
    }
}

Describe 'Illustrative cost scenario arithmetic' {
    It 'applies only the eligible share of the baseline to the hours off over a 168-hour week' {
        $result = Get-DemoOperationalScenario -MonthlyBaseline 1000 -EligibleSharePercent 60 -WeeklyHoursOff 108
        $result.EligibleBaseline | Should -Be 600
        $result.IllustrativeReduction | Should -Be ([decimal]600 * 108 / 168)
        $result.FixedBaseline | Should -Be 400
        $result.IllustrativeBaselineAfter | Should -Be (1000 - [decimal]600 * 108 / 168)
        $result.IllustrativeReduction | Should -BeOfType decimal
    }

    It 'is zero when nothing is configured and rejects out-of-range inputs' {
        (Get-DemoOperationalScenario).IllustrativeReduction | Should -Be 0
        (Get-DemoOperationalScenario -MonthlyBaseline 500 -EligibleSharePercent 100 -WeeklyHoursOff 168).IllustrativeReduction | Should -Be 500
        { Get-DemoOperationalScenario -MonthlyBaseline -1 } | Should -Throw
        { Get-DemoOperationalScenario -EligibleSharePercent 101 } | Should -Throw
        { Get-DemoOperationalScenario -WeeklyHoursOff 169 } | Should -Throw
    }

    It 'keeps the workbook scenario unconfigured by default, labelled as illustration and never a guest scenario' {
        $book = (Get-DemoOperationalWorkbook -Purpose optimisation -WorkspaceResourceId $workspaceId -Machines $machines).SerializedData | ConvertFrom-Json -Depth 100
        $params = @(Get-WorkbookItems $book.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters })
        ($params | Where-Object name -eq 'ScenarioBaseline').value | Should -Be '0'
        ($params | Where-Object name -eq 'ScenarioSharePct').value | Should -Be 'none'
        ($params | Where-Object name -eq 'SchedStartHour').value | Should -Be 'none'
        $query = (Get-WorkbookItems $book.items | Where-Object name -eq 'scenario-tiles').content.query
        $query | Should -Match 'SelectedLayer != "guest"'
        $query | Should -Match 'Eligible \* WeeklyOffHours / 168\.0'
        $result = (Get-WorkbookItems $book.items | Where-Object name -eq 'scenario-result-tiles').content.query
        $result | Should -Match 'not billing, not realised or guaranteed savings'
        $result | Should -Match 'not billing, not realised savings'
    }
}

Describe 'Shared query composition' {
    It 'prepends the roster preamble and the included fragments once, in dependency order' {
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $machines)
        $query = Get-DemoOperationalQuery -Name opt-tiles -Roster $roster
        $order = 'let AllMachines', 'let PerfRows = Perf', 'let Summary = ', 'let Hosts = ', 'let Candidates = '
        $last = -1
        foreach ($marker in $order) {
            $index = $query.IndexOf($marker)
            $index | Should -BeGreaterThan $last
            $last = $index
            $query.IndexOf($marker, $index + 1) | Should -Be -1
        }
    }

    It 'rejects unknown, malformed or circular shared queries' {
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $machines)
        { Get-DemoOperationalQuery -Name 'no-such-query' -Roster $roster } | Should -Throw '*not found*'
        { Get-DemoOperationalQuery -Name '../evil' -Roster $roster } | Should -Throw '*Invalid*'
        { Get-DemoOperationalArgQuery -Name 'Bad Name' -Roster $roster } | Should -Throw '*Invalid*'
    }

    It 'expands workbook placeholders for offline execution and rejects any left unresolved' {
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $machines)
        $query = Get-DemoOperationalQuery -Name cap-hosts -Roster $roster
        $query | Should -Match '\{TimeRange:startISO\}'
        $expanded = Expand-DemoOperationalQuery -Query $query -Roster $roster -Start ([datetime]'2026-01-01T00:00:00Z') -End ([datetime]'2026-01-08T00:00:00Z')
        $expanded | Should -Match "todatetime\('2026-01-01T00:00:00.000Z'\)"
        $expanded | Should -Not -Match '\{[A-Za-z][A-Za-z0-9]*(:[A-Za-z]+)?\}'
        { Expand-DemoOperationalQuery -Query 'print {Unknown}' -Roster $roster } | Should -Throw '*Unresolved*'
    }

    It 'confines the exact roster IDs to the Resource Graph item' {
        $roster = @(Get-DemoOperationalRoster -WorkspaceResourceId $workspaceId -Machines $machines)
        $query = Get-DemoOperationalArgQuery -Name cap-arc-status -Roster $roster
        $query | Should -Match ([regex]::Escape($parentId.ToLowerInvariant()))
        $query | Should -Not -Match '__ROSTER_IDS__'
    }
}

Describe 'Workbook-only entry point' {
    BeforeAll {
        Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
        $scriptPath = Join-Path $repo 'scripts\Set-OperationalWorkbook.ps1'
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Get-DemoSkin { @{} }
        Mock Initialize-DemoContext {}
        Mock Assert-DemoName {}
        $mockState = @{ existingWorkbook = $null; deploymentParameters = $null; expectedId = ''; deploymentState = 'Succeeded'; readbackDrift = $false; machines = $machines }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'connectedmachine') { return ($mockState.machines | ConvertTo-Json -Depth 5 -AsArray) }
            if ($Arguments[0] -eq 'deployment') {
                $mockState.deploymentParameters = Get-Content ($Arguments[10].TrimStart('@')) -Raw | ConvertFrom-Json -Depth 20
                $mockState.deploymentName = $Arguments[6]
                return (@{ properties = @{ provisioningState = $mockState.deploymentState; outputs = @{ workbookResourceId = @{ value = $mockState.expectedId } } } } | ConvertTo-Json -Depth 8)
            }
            if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'delete') { $mockState.existingWorkbook = $null; return }
            if ($Arguments[0] -eq 'resource' -and $Arguments[3] -eq $workspaceId) {
                return (@{ id = $workspaceId; location = 'australiaeast' } | ConvertTo-Json)
            }
            if ($Arguments[0] -eq 'resource') {
                return $mockState.existingWorkbook
            }
            throw "Unexpected CLI operation $($Arguments -join ' ')"
        }
        Mock Invoke-AzRest {
            [pscustomobject]@{ id = $mockState.expectedId; tags = @{ managedBy = 'arc-demo-operational-workbooks' }; properties = @{
                sourceId = $workspaceId; serializedData = if ($mockState.readbackDrift) { '{}' } else { $mockState.deploymentParameters.parameters.serializedData.value }
            } }
        }
        $argsForScript = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'
            Purpose = 'capacity'; WorkspaceResourceId = $workspaceId; NamePrefix = 'fixture'
        }
        $mockState.expectedId = (Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines).ResourceId
        $draftId = (Get-DemoOperationalWorkbook -Purpose capacity -WorkspaceResourceId $workspaceId -Machines $machines -Draft).ResourceId
    }

    It 'defaults to a read-only preview without any deployment' {
        $result = & $scriptPath @argsForScript
        $result.status | Should -Be preview
        $result.published | Should -BeFalse
        $result.draft | Should -BeFalse
        Should -Invoke Initialize-DemoContext -Times 1
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'keeps Deploy WhatIf read-only and never reports publication' {
        $result = & $scriptPath @argsForScript -Action Deploy -WhatIf
        $result.published | Should -BeFalse
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'rejects a foreign existing workbook rather than taking ownership' {
        $mockState.existingWorkbook = @{ id = $mockState.expectedId; kind = 'shared'; tags = @{ managedBy = 'someone-else' }; properties = @{ sourceId = $workspaceId } } | ConvertTo-Json
        { & $scriptPath @argsForScript } | Should -Throw '*ownership/source*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'surfaces denied reads and does not fall back to absent' {
        Mock Invoke-DemoAz { throw 'AuthorizationFailed' }
        { & $scriptPath @argsForScript } | Should -Throw '*AuthorizationFailed*'
    }

    It 'deploys only the workbook module and verifies exact serialized content when approved' {
        $result = & $scriptPath @argsForScript -Action Deploy -Confirm:$false
        $result.published | Should -BeTrue
        $result.status | Should -Be published
        $mockState.deploymentParameters.parameters.draft.value | Should -BeFalse
        $mockState.deploymentParameters.parameters.displayName.value | Should -Be 'Capacity and headroom'
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter {
            $Arguments[0] -eq 'deployment' -and $Arguments[8] -like '*operational-workbook.bicep'
        }
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and $Url -eq "https://management.azure.com$($mockState.expectedId)?api-version=2023-06-01&canFetchContent=true"
        }
    }

    It 'deploys a separate draft copy and never touches the published workbook' {
        $mockState.expectedId = $draftId
        $result = & $scriptPath @argsForScript -Action Deploy -Draft -Confirm:$false
        $result.status | Should -Be draft-published
        $result.published | Should -BeFalse
        $result.draft | Should -BeTrue
        $result.workbookResourceId | Should -Be $draftId
        $result.workbookResourceId | Should -Not -Match ([regex]::Escape(($mockState.deploymentParameters.parameters.workbookName.value) + 'x'))
        $mockState.deploymentParameters.parameters.draft.value | Should -BeTrue
        $mockState.deploymentParameters.parameters.displayName.value | Should -Be 'Capacity and headroom (draft)'
        $mockState.deploymentName | Should -Match '-draft$'
        $mockState.deploymentParameters.parameters.serializedData.value | Should -Match 'DRAFT for review'
    }

    It 'rejects a workbook whose draft marking does not match the request' {
        $mockState.existingWorkbook = @{
            id = $mockState.expectedId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity'; lifecycle = 'draft' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        { & $scriptPath @argsForScript -Action Deploy -Confirm:$false } | Should -Throw '*draft marking*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'removes only an owned draft and verifies it is gone' {
        $mockState.expectedId = $draftId
        $mockState.existingWorkbook = @{
            id = $draftId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity'; lifecycle = 'draft' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        $result = & $scriptPath @argsForScript -Action Remove -Draft -Confirm:$false
        $result.status | Should -Be removed
        $result.removed | Should -BeTrue
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'delete' -and $Arguments[3] -eq $draftId }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'connectedmachine' }
    }

    It 'removes an owned draft even when the Arc roster is empty or unreadable' {
        $mockState.expectedId = $draftId
        $mockState.machines = @()
        $mockState.existingWorkbook = @{
            id = $draftId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity'; lifecycle = 'draft' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        (& $scriptPath @argsForScript -Action Remove -Draft -Confirm:$false).status | Should -Be removed
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'connectedmachine' }
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'resource' -and $Arguments[3] -eq $workspaceId }
    }

    It 'never removes the published workbook and keeps Remove WhatIf read-only' {
        { & $scriptPath @argsForScript -Action Remove -Confirm:$false } | Should -Throw '*Only a draft*'
        $mockState.existingWorkbook = @{
            id = $draftId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity'; lifecycle = 'draft' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        $result = & $scriptPath @argsForScript -Action Remove -Draft -WhatIf
        $result.removed | Should -BeFalse
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'delete' }
    }

    It 'reports an absent draft instead of failing' {
        $result = & $scriptPath @argsForScript -Action Remove -Draft -Confirm:$false
        $result.status | Should -Be absent
    }

    It 'updates an owned same-source workbook idempotently rather than duplicating it' {
        $mockState.existingWorkbook = @{
            id = $mockState.expectedId; kind = 'shared'
            tags = @{ managedBy = 'arc-demo-operational-workbooks'; purpose = 'capacity' }
            properties = @{ sourceId = $workspaceId }
        } | ConvertTo-Json -Depth 6
        $result = & $scriptPath @argsForScript -Action Deploy -Confirm:$false
        $result.workbookResourceId | Should -Be $mockState.expectedId
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'rejects a metadata-only readback without reporting publication' {
        Mock Invoke-AzRest {
            [pscustomobject]@{ id = $mockState.expectedId; tags = @{ managedBy = 'arc-demo-operational-workbooks' }
                properties = @{ sourceId = $workspaceId; serializedData = $null } }
        }
        { & $scriptPath @argsForScript -Action Deploy -Confirm:$false } | Should -Throw '*readback differs*'
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'fails unknown deployment or content readback without retry or success-shaped output' -ForEach @(
        @{ State = 'Running'; Drift = $false; ExpectedError = '*failed/unknown*' }
        @{ State = 'Succeeded'; Drift = $true; ExpectedError = '*readback differs*' }
    ) {
        $mockState.deploymentState = $State
        $mockState.readbackDrift = $Drift
        { & $scriptPath @argsForScript -Action Deploy -Confirm:$false } | Should -Throw $ExpectedError
        Should -Invoke Invoke-DemoAz -Times 1 -ParameterFilter { $Arguments[0] -eq 'deployment' }
    }

    It 'declares the skin nestedSqlGuest as parent and guest and tolerates a guest that is not onboarded yet' {
        Mock Get-DemoSkin { @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'parent'; guestVmName = 'guest-vm'; arcMachineName = 'guest' } } }
        $result = & $scriptPath @argsForScript
        $text = (Get-WorkbookItems $result.workbook.items | Where-Object { $_.type -eq 3 } | Select-Object -First 1).content.query
        $text | Should -Match '"layer":"guest"'
        $text | Should -Match '"layer":"parent"'
        $mockState.machines = @($machines[0])
        $warnings = $null
        $partial = & $scriptPath @argsForScript -WarningVariable warnings -WarningAction SilentlyContinue
        "$warnings" | Should -Match 'not present yet'
        (Get-WorkbookItems $partial.workbook.items | Where-Object { $_.type -eq 3 } | Select-Object -First 1).content.query | Should -Not -Match '"layer":"guest"'
    }

    It 'rejects a topology file that conflicts with the skin nested guest declaration' {
        Mock Get-DemoSkin { @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'parent'; guestVmName = 'guest-vm'; arcMachineName = 'guest' } } }
        $topologyFile = Join-Path $TestDrive 'conflict.json'
        (@{ schemaVersion = 1; machines = @(@{ resourceId = $parentId; layer = 'standalone' }) } | ConvertTo-Json -Depth 5) | Set-Content $topologyFile
        { & $scriptPath @argsForScript -TopologyPath $topologyFile } | Should -Throw '*conflicts*'
    }

    It 'rejects malformed topology before any Azure operation' {
        $topologyFile = Join-Path $TestDrive 'bad-topology.json'
        '{"schemaVersion":"1","machines":[]}' | Set-Content $topologyFile
        { & $scriptPath @argsForScript -TopologyPath $topologyFile } | Should -Throw '*Topology must contain*'
        Should -Invoke Initialize-DemoContext -Times 0
        Should -Invoke Invoke-DemoAz -Times 0
    }
}
