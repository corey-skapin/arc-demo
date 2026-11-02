BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'), [ref]$tokens, [ref]$errors)
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-WorkbookWorkspaceDefaults'
    }, $true)
    if (-not $function -or $errors) { throw 'Workbook binding function could not be loaded for isolated tests.' }
    . ([scriptblock]::Create($function.Extent.Text))
    $workspace = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture'
}

Describe 'Workbook workspace scope is injected at publish, never stored in the repo' {
    It 'replaces the placeholder in every Log Analytics scope and in the fallback resource list' {
        $fixture = @{
            version = 'Notebook/1.0'
            fallbackResourceIds = @('__WORKSPACE__')
            items = @(
                @{ type = 3; content = @{ queryType = 0; query = 'Heartbeat | take 1'; crossComponentResources = @('__WORKSPACE__') } }
                @{ type = 12; content = @{ items = @(
                    @{ type = 3; content = @{ queryType = 0; query = 'Perf | take 1'; crossComponentResources = @('__WORKSPACE__') } }
                ) } }
                @{ type = 3; content = @{ queryType = 1; query = 'resources | take 1'; crossComponentResources = @('value::all') } }
            )
        } | ConvertTo-Json -Depth 20
        $bound = Set-WorkbookWorkspaceDefaults -SerializedData $fixture -DefaultWorkspaceId $workspace
        $bound | Should -Not -Match '__WORKSPACE__'
        $book = $bound | ConvertFrom-Json -Depth 100
        @($book.fallbackResourceIds) | Should -Be @($workspace)
        @($book.items[0].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[1].content.items[0].content.crossComponentResources) | Should -Be @($workspace)
        @($book.items[2].content.crossComponentResources) | Should -Be @('value::all')
    }

    It 'still binds a cleared workspace picker by name' {
        $fixture = @{ version = 'Notebook/1.0'; items = @(
            @{ type = 9; content = @{ parameters = @(@{ name = 'LogAnalyticsWorkspace'; type = 5; label = 'Log Analytics Workspace' }) } }
        ) } | ConvertTo-Json -Depth 20
        $book = Set-WorkbookWorkspaceDefaults -SerializedData $fixture -DefaultWorkspaceId $workspace | ConvertFrom-Json -Depth 100
        $book.items[0].content.parameters[0].value | Should -Be $workspace
    }
}
