BeforeDiscovery {
    $books = @(
        @{ Name = 'Arc - Asset Inventory'; Path = 'workbooks\arc-asset-inventory.workbook.json' }
        @{ Name = 'Arc - Compliance, Security & Governance'; Path = 'workbooks\arc-compliance.workbook.json' }
        @{ Name = 'Arc - Governance & Compliance (experimental)'; Path = 'workbooks\nseilaz\GovernanceComplianceWorkbook_Experiment.json' }
        @{ Name = 'Arc - Machine Intelligence Center'; Path = 'workbooks\nseilaz\ArcMachineIntelligenceCenter.json' }
        @{ Name = 'Arc - SQL Estate Dashboard'; Path = 'workbooks\nseilaz\SQL_Estate_Dashboard.json' }
    )
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $deployPath = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$tokens, [ref]$errors)
    if ($errors) { throw 'Deploy-ArcDemo.ps1 did not parse.' }
    foreach ($name in 'Set-WorkbookWorkspaceDefaults', 'Publish-Workbook') {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $function) { throw "$name could not be loaded for isolated tests." }
        . ([scriptblock]::Create($function.Extent.Text))
    }

    $workspace = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture'
    $workspaceId = $workspace
    $SubscriptionId = '11111111-1111-1111-1111-111111111111'
    $arcRg = 'rg-fixture'
    $Location = 'australiaeast'
    $demoTags = @{ owner = 'demo' }
    $script:putBodies = @{}

    # Publish-Workbook's collaborators, faked so nothing leaves the process.
    function az { $null }
    function Merge-DemoHashtable { param($Defaults, $Overrides) $merged = @{} + $Defaults; foreach ($k in $Overrides.Keys) { $merged[$k] = $Overrides[$k] }; $merged }
    function Write-Ok { param($Message) }
    function Write-Warn { param($Message) }
    function Invoke-AzRest {
        param($Method, $Url, $Body)
        $script:putBodies[$Body.properties.displayName] = $Body
        [pscustomobject]@{ id = ($Url -replace '\?.*$', ''); properties = [pscustomobject]@{ displayName = $Body.properties.displayName } }
    }

    function Get-LogAnalyticsScope($Items) {
        foreach ($item in @($Items)) {
            if (-not $item.content) { continue }
            if ($item.type -eq 12) { Get-LogAnalyticsScope $item.content.items; continue }
            $isLogAnalytics = { param($node) $node.queryType -eq 0 -and (-not $node.resourceType -or $node.resourceType -eq 'microsoft.operationalinsights/workspaces') }
            if ($item.type -in 3, 9 -and (& $isLogAnalytics $item.content)) { $item.content }
            if ($item.type -eq 9) { foreach ($parameter in @($item.content.parameters)) { if (& $isLogAnalytics $parameter) { $parameter } } }
        }
    }
}

Describe 'Workbook workspace scope is stamped at publish, never stored in the repo' {
    It 'pins every Log Analytics item, group member and Log Analytics parameter and sets the fallback list' {
        $fixture = @{
            version = 'Notebook/1.0'
            items = @(
                @{ type = 3; content = @{ queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'; query = 'Heartbeat | take 1'; crossComponentResources = @('{LogAnalyticsWorkspace}') } }
                @{ type = 3; content = @{ queryType = 0; query = 'Heartbeat | take 1' } }
                @{ type = 12; content = @{ items = @(
                    @{ type = 3; content = @{ queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'; query = 'Perf | take 1'; crossComponentResources = @() } }
                    @{ type = 12; content = @{ items = @(
                        @{ type = 3; content = @{ queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'; query = 'Event | take 1'; crossComponentResources = @('value::all') } }
                    ) } }
                ) } }
                @{ type = 9; content = @{ parameters = @(
                    @{ name = 'Pick'; type = 2; queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'; query = 'Heartbeat | distinct Computer'; crossComponentResources = @('{LogAnalyticsWorkspace}') }
                ) } }
                @{ type = 3; content = @{ queryType = 1; resourceType = 'microsoft.resourcegraph/resources'; query = 'resources | take 1'; crossComponentResources = @('value::all') } }
                @{ type = 3; content = @{ queryType = 0; resourceType = 'microsoft.insights/components'; query = 'requests | take 1'; crossComponentResources = @('/subscriptions/x/resourceGroups/y/providers/microsoft.insights/components/z') } }
            )
        } | ConvertTo-Json -Depth 20
        $book = Set-WorkbookWorkspaceDefaults -SerializedData $fixture -DefaultWorkspaceId $workspace | ConvertFrom-Json -Depth 100
        @($book.fallbackResourceIds) | Should -Be @($workspace)
        @($book.items[0].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[1].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[2].content.items[0].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[2].content.items[1].content.items[0].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[3].content.parameters[0].crossComponentResources) | Should -Be @($workspace)
        @($book.items[4].content.crossComponentResources) | Should -Be @('value::all')
        @($book.items[5].content.crossComponentResources) | Should -Be @('/subscriptions/x/resourceGroups/y/providers/microsoft.insights/components/z')
    }

    It 'still binds a cleared workspace picker by name' {
        $fixture = @{ version = 'Notebook/1.0'; items = @(
            @{ type = 9; content = @{ parameters = @(@{ name = 'LogAnalyticsWorkspace'; type = 5; label = 'Log Analytics Workspace' }) } }
        ) } | ConvertTo-Json -Depth 20
        $book = Set-WorkbookWorkspaceDefaults -SerializedData $fixture -DefaultWorkspaceId $workspace | ConvertFrom-Json -Depth 100
        $book.items[0].content.parameters[0].value | Should -Be $workspace
    }

    It 'publishes <Name> from the repo JSON with every Log Analytics item pinned and nothing real left behind' -ForEach $books {
        $null = Publish-Workbook -FilePath (Join-Path $repo $Path) -DisplayName $Name
        $body = $script:putBodies[$Name]
        $body | Should -Not -BeNullOrEmpty
        $body.properties.sourceId | Should -Be $workspace.ToLower()
        $stored = [string]$body.properties.serializedData
        $stored | Should -Not -Match '__WORKSPACE__'
        $storedBook = $stored | ConvertFrom-Json -Depth 100
        @($storedBook.fallbackResourceIds) | Should -Be @($workspace.ToLower())
        $scoped = @(Get-LogAnalyticsScope $storedBook.items)
        foreach ($node in $scoped) { @($node.crossComponentResources) | Should -Be @($workspace.ToLower()) -Because ([string]$node.title + [string]$node.name) }
        foreach ($match in [regex]::Matches($stored, '/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')) {
            $match.Groups[1].Value | Should -Be '11111111-1111-1111-1111-111111111111' -Because 'only the fake deployment subscription may appear in stored content'
        }
        foreach ($other in [regex]::Matches($stored, '(?i)providers/Microsoft\.OperationalInsights/workspaces/([^"/\\]+)')) {
            $other.Groups[1].Value | Should -Be 'law-fixture'
        }
        foreach ($picker in @($storedBook.items | Where-Object type -eq 9 | ForEach-Object { $_.content.parameters } | Where-Object { $_.type -eq 5 -and $_.name -in 'LogAnalyticsWorkspace', 'p_ws' })) {
            $picker.value | Should -Be $workspace.ToLower() -Because $picker.name
        }
    }

    It 'keeps a Log Analytics tile in at least the rebuilt workbooks so the pin is exercised' {
        foreach ($case in $books | Where-Object { $_.Name -in 'Arc - Asset Inventory', 'Arc - Compliance, Security & Governance', 'Arc - Machine Intelligence Center', 'Arc - SQL Estate Dashboard' }) {
            $null = Publish-Workbook -FilePath (Join-Path $repo $case.Path) -DisplayName $case.Name
            $storedBook = [string]$script:putBodies[$case.Name].properties.serializedData | ConvertFrom-Json -Depth 100
            @(Get-LogAnalyticsScope $storedBook.items).Count | Should -BeGreaterThan 0 -Because $case.Name
        }
    }

    It 'publishes all five workbooks from Phase 11' {
        $deploy = Get-Content -LiteralPath $deployPath -Raw
        foreach ($case in $books) { $deploy | Should -Match ([regex]::Escape((Split-Path $case.Path -Leaf))) -Because $case.Name }
    }
}
