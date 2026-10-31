BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $generator = Join-Path $repo 'scripts\New-PresenterRunsheet.ps1'
}

Describe 'Offline private presenter guide' {
    BeforeEach {
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '\.local')
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        $path = Join-Path $local 'demo-context.json'
        $output = Join-Path $local 'presenter-runsheet.md'
        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
        $context = @{
            schemaVersion = 1
            subscriptionId = '11111111-1111-1111-1111-111111111111'
            tenantId = '22222222-2222-2222-2222-222222222222'
            recordedAtUtc = '2026-10-20T01:02:03Z'
            resourceGroups = @{ arc = 'rg-fixture'; infra = 'rg-fixture-infra' }
            workspaceResourceId = "$scope/providers/Microsoft.OperationalInsights/workspaces/law-fixture"
            workbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/33333333-3333-3333-3333-333333333333"
            windowsMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/windows-fixture"
            linuxMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/linux-fixture"
            heartbeatAlertResourceId = "$scope/providers/Microsoft.Insights/scheduledQueryRules/alert-fixture"
            actionGroupResourceId = "$scope/providers/Microsoft.Insights/actionGroups/ag-fixture"
            lobMachineName = 'windows-fixture'
        }
        Mock Invoke-RestMethod { throw 'Offline generation must not query Azure.' }
        Mock Start-Process { throw 'Offline generation must not launch tools.' }
    }

    It 'fills concrete tenant/resource links and scoped queries without querying Azure' {
        $context | ConvertTo-Json | Set-Content $path
        $result = & $generator -ContextPath $path
        $result.Path | Should -Be $output
        $result.AzureQueried | Should -BeFalse
        $text = Get-Content $output -Raw
        $text | Should -Match ([regex]::Escape("https://portal.azure.com/#@$($context.tenantId)/resource$($context.workbookResourceId)"))
        $text | Should -Match ([regex]::Escape($scope.ToLowerInvariant()))
        $text | Should -Match 'Computer =~ "windows-fixture"'
        $text | Should -Not -Match '\{\{|\}\}|<SUB|PRIVATE_SKIN|input.card from'
        $text | Should -Match '2026-10-20T01:02:03'
        $text | Should -Match 'not a fresh readiness'
        $text | Should -Not -Match '(?:\r?\n){3}$'
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'does not guess a LOB installation or companion path when omitted' {
        $context.Remove('lobMachineName')
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'No LOB host is recorded'
        $text | Should -Not -Match '\[SRE presenter guide\]'
        $text | Should -Match 'where false'
        $text | Should -Match 'No verified real SQL workload'
        $text | Should -Match 'not recorded as published'
    }

    It 'adds optional published operational links in the same guide without claiming health' {
        $context.capacityWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/44444444-4444-4444-4444-444444444444"
        $context.optimisationWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/55555555-5555-5555-5555-555555555555"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match '\[Capacity and headroom\]\(https://portal.azure.com/'
        $text | Should -Match '\[Optimisation opportunities\]\(https://portal.azure.com/'
        $text | Should -Match 'not current telemetry health'
        $text | Should -Not -Match '\{\{|\}\}'
    }

    It 'rejects a foreign or wrong-type operational workbook link' -ForEach @(
        @{ Resource = 'Microsoft.Compute/virtualMachines/not-a-workbook' }
        @{ Resource = 'Microsoft.Insights/workbooks/nested/name' }
    ) {
        $context.capacityWorkbookResourceId = "$scope/providers/$Resource"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*expected resource type*'
        Test-Path $output | Should -BeFalse
    }

    It 'requires real saved engine/query proof before enabling the SQL step' {
        $context.sqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/sql-fixture"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*requires adjacent sql-engine-status.json*'
        Test-Path $output | Should -BeFalse
    }

    It 'renders dated real SQL evidence and the exact host scope when explicitly prepared' {
        $context.sqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/sql-fixture"
        $context.sqlIncidentAlertResourceId = "$scope/providers/Microsoft.Insights/scheduledQueryRules/al-fixture-sql-lock-timeout"
        $context | ConvertTo-Json | Set-Content $path
        @{
            schemaVersion = 1; workload = 'arc-sql-engine'; action = 'Status'; resourceId = $context.sqlMachineResourceId
            evidence = @{
                status = 'pass'; instance = 'ARCDEMO'; database = 'ArcDemoOrders'; edition = 'Developer Edition (64-bit)'
                version = '16.0.1000.6'; orderCount = 7; checkedAtUtc = '2026-10-20T01:02:03Z'; lastCommitUtc = '2026-10-20T01:01:53Z'
            }
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $local 'sql-engine-status.json')
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match '16.0.1000.6 Developer'
        $text | Should -Match '7 rows'
        $text | Should -Match '\(sql-engine-status.json\)'
        $text | Should -Match ([regex]::Escape($context.sqlMachineResourceId.ToLowerInvariant()))
        $text | Should -Match 'dated evidence, not a new guest query'
        $text | Should -Match '\[SQL incident alert\]\(https://portal.azure.com/'
        $text | Should -Match 'not proof of an alert firing'
    }

    It 'does not enable an incident link without prepared engine evidence' {
        $context.sqlIncidentAlertResourceId = "$scope/providers/Microsoft.Insights/scheduledQueryRules/al-fixture-sql-lock-timeout"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*requires the prepared real SQL host*'
        Test-Path $output | Should -BeFalse
    }

    It 'rejects inconsistent/foreign/pending SQL proof' -ForEach @(
        @{ Status = 'pending'; Resource = 'sql-fixture'; Count = 7 }
        @{ Status = 'pass'; Resource = 'other-fixture'; Count = 7 }
        @{ Status = 'pass'; Resource = 'sql-fixture'; Count = '7' }
    ) {
        $context.sqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/sql-fixture"
        $context | ConvertTo-Json | Set-Content $path
        @{
            schemaVersion = 1; workload = 'arc-sql-engine'; action = 'Status'; resourceId = "$scope/providers/Microsoft.HybridCompute/machines/$Resource"
            evidence = @{
                status = $Status; instance = 'ARCDEMO'; database = 'ArcDemoOrders'; edition = 'Developer Edition (64-bit)'
                version = '16.0.1000.6'; orderCount = $Count; checkedAtUtc = '2026-10-20T01:02:03Z'; lastCommitUtc = '2026-10-20T01:01:53Z'
            }
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $local 'sql-engine-status.json')
        { & $generator -ContextPath $path } | Should -Throw '*Saved SQL evidence is incomplete*'
        Test-Path $output | Should -BeFalse
    }

    It 'resolves a relative context against the PowerShell working directory' {
        $context | ConvertTo-Json | Set-Content $path
        Push-Location (Split-Path $local)
        try {
            $result = & $generator -ContextPath '.\.local\demo-context.json'
            $result.Path | Should -Be $output
        } finally { Pop-Location }
    }

    It 'escapes valid resource-name parentheses inside Markdown portal links' {
        $context.actionGroupResourceId += '(ops)'
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        Get-Content $output -Raw | Should -Match 'actionGroups/ag-fixture%28ops%29\)'
    }

    It 'links to an existing companion relative to the generated file, including spaces' {
        $companion = Join-Path $TestDrive 'companion folder\.local\presenter-runsheet.md'
        New-Item -ItemType Directory -Path (Split-Path $companion) -Force | Out-Null
        Set-Content $companion '# SRE fixture'
        $context.companionSreRunsheetPath = $companion
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $match = [regex]::Match($text, '\[SRE presenter guide\]\(([^)]+)\)')
        $match.Success | Should -BeTrue
        $match.Groups[1].Value | Should -Match 'companion%20folder'
        $resolved = [IO.Path]::GetFullPath((Join-Path $local ([uri]::UnescapeDataString($match.Groups[1].Value) -replace '/', '\')))
        $resolved | Should -Be $companion
        Test-Path -LiteralPath $resolved -PathType Leaf | Should -BeTrue
    }

    It 'does not emit a broken companion link when the optional file is absent' {
        $context.companionSreRunsheetPath = Join-Path $TestDrive 'absent\.local\presenter-runsheet.md'
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        Get-Content $output -Raw | Should -Not -Match '\[SRE presenter guide\]'
    }

    It 'fails explicitly on a missing context' {
        { & $generator -ContextPath $path } | Should -Throw '*context is missing*'
        Test-Path $output | Should -BeFalse
    }

    It 'fails explicitly on malformed JSON without replacing an earlier guide' {
        Set-Content $path '{broken'
        Set-Content $output 'retained guide'
        { & $generator -ContextPath $path } | Should -Throw
        (Get-Content $output -Raw).Trim() | Should -Be 'retained guide'
    }

    It 'rejects incomplete context before replacing an earlier guide' {
        $context.Remove('workbookResourceId')
        $context | ConvertTo-Json | Set-Content $path
        Set-Content $output 'retained guide'
        { & $generator -ContextPath $path } | Should -Throw '*workbookResourceId*missing*'
        (Get-Content $output -Raw).Trim() | Should -Be 'retained guide'
    }

    It 'rejects credentials or unsupported fields instead of copying a whole runtime file' {
        $context.password = 'fixture-not-a-real-secret'
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*Unsupported context field*'
        Test-Path $output | Should -BeFalse
    }

    It 'rejects unexpected nested context fields' {
        $context.resourceGroups.password = 'fixture-not-a-real-secret'
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*Unsupported resourceGroups field*'
        Test-Path $output | Should -BeFalse
    }

    It 'requires explicit valid IDs and dated context' -ForEach @(
        @{ Field = 'tenantId'; Value = 'not-a-guid' }
        @{ Field = 'subscriptionId'; Value = '00000000-0000-0000-0000-000000000000' }
        @{ Field = 'recordedAtUtc'; Value = 'yesterday' }
        @{ Field = 'recordedAtUtc'; Value = 'October 20, 2026 01:02:03Z' }
        @{ Field = 'schemaVersion'; Value = '1' }
    ) {
        $context[$Field] = $Value
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw
        Test-Path $output | Should -BeFalse
    }

    It 'rejects wrong subscription, group, resource type or Markdown injection' -ForEach @(
        @{ Id = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/other' }
        @{ Id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-other/providers/Microsoft.OperationalInsights/workspaces/other' }
        @{ Id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.Compute/virtualMachines/backing' }
        @{ Id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/bad)[link](url' }
    ) {
        $context.workspaceResourceId = $Id
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*workspaceResourceId*'
        Test-Path $output | Should -BeFalse
    }

    It 'keeps output inside the private .local convention' {
        $unsafe = Join-Path $TestDrive 'tracked-context.json'
        $context | ConvertTo-Json | Set-Content $unsafe
        { & $generator -ContextPath $unsafe } | Should -Throw '*private identifiers*'
    }

    It 'supports a local preview without overwriting the existing guide' {
        $context | ConvertTo-Json | Set-Content $path
        Set-Content $output 'retained guide'
        & $generator -ContextPath $path -WhatIf
        (Get-Content $output -Raw).Trim() | Should -Be 'retained guide'
    }

    It 'keeps the entire local context and Markdown output out of git' {
        $ignore = Get-Content (Join-Path $repo '.gitignore')
        $ignore | Should -Contain '.local/'
    }
}
