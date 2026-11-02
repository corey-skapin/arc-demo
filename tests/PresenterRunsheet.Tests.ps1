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

    It 'renders the nested Arc SQL scene with its links and states the support boundary' {
        $context.nestedSqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/nested-fixture"
        $context.nestedSqlInstanceResourceId = "$scope/providers/Microsoft.AzureArcData/SqlServerInstances/nested-fixture"
        $context.nestedSqlParentMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/parent-fixture"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'Prepared nested guest: the nested guest''s Arc machine \[nested-fixture\]\(https://portal.azure.com/'
        $text | Should -Match 'SqlServerInstances/nested-fixture\)'
        $text | Should -Match 'backing parent host \[parent-fixture\]\(https://portal.azure.com/'
        $text | Should -Match 'These links are not proof of current state'
        $text | Should -Match 'experimental'
        $text | Should -Match 'license-only'
        $text | Should -Match 'Do not claim Monitoring, best practices assessment or Defender for SQL'
        $text | Should -Not -Match '\{\{|\}\}'
    }

    It 'skips the nested part of the SQL chapter, links and incident rules plainly when they are not recorded' {
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'No nested Arc SQL guest is recorded in this context; skip the nested Arc SQL part of this chapter'
        $text | Should -Match 'No LOB alert rule is recorded'
        $text | Should -Match 'No SQL incident alert is recorded'
        $text | Should -Match 'No data collection rule is recorded in this context'
        $text | Should -Not -Match 'Prepared nested guest'
    }

    It 'links the resource group and the data collection rule without new inputs beyond the saved IDs' {
        $context.dataCollectionRuleResourceId = "$scope/providers/Microsoft.Insights/dataCollectionRules/dcr-fixture"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match ([regex]::Escape("https://portal.azure.com/#@$($context.tenantId)/resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/overview"))
        $text | Should -Match '\[the data collection rule\]\(https://portal.azure.com/.*dataCollectionRules/dcr-fixture\), \*\*dcr-fixture\*\*, read-only'
    }

    It 'renders a LOB alert rule link only for a prepared LOB host' {
        $context.lobIncidentAlertResourceId = "$scope/providers/Microsoft.Insights/scheduledQueryRules/alert-fixture-lob"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match '\[LOB alert rule\]\(https://portal.azure.com/.*alert-fixture-lob\)'
        $text | Should -Match 'not proof of an alert firing or an SRE investigation'
        $context.Remove('lobMachineName')
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*requires the prepared lobMachineName*'
    }

    It 'requires the nested guest machine before its instance or parent' -ForEach @(
        @{ Field = 'nestedSqlInstanceResourceId'; Resource = 'Microsoft.AzureArcData/SqlServerInstances/nested-fixture' }
        @{ Field = 'nestedSqlParentMachineResourceId'; Resource = 'Microsoft.HybridCompute/machines/parent-fixture' }
    ) {
        $context[$Field] = "$scope/providers/$Resource"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*requires the nested guest Arc machine*'
        Test-Path $output | Should -BeFalse
    }

    It 'rejects a wrong-type or foreign nested or incident link' -ForEach @(
        @{ Field = 'nestedSqlMachineResourceId'; Resource = 'Microsoft.Compute/virtualMachines/backing' }
        @{ Field = 'dataCollectionRuleResourceId'; Resource = 'Microsoft.Insights/dataCollectionEndpoints/dce-fixture' }
        @{ Field = 'lobIncidentAlertResourceId'; Resource = 'Microsoft.Insights/actionGroups/ag-fixture' }
    ) {
        $context.nestedSqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/nested-fixture"
        $context[$Field] = "$scope/providers/$Resource"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*expected resource type*'
        Test-Path $output | Should -BeFalse
    }

    It 'rejects a nested guest in another resource group' {
        $context.nestedSqlMachineResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-other/providers/Microsoft.HybridCompute/machines/nested-fixture'
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*nestedSqlMachineResourceId*'
        Test-Path $output | Should -BeFalse
    }

    It 'links the optional original workbooks and skips them plainly when they are not recorded' {
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'The Machine Intelligence Center workbook is not recorded in this context; skip its steps in this chapter'
        $text | Should -Match 'The compliance workbook is not recorded in this context; skip its steps in this chapter'
        $text | Should -Match 'The Asset Inventory workbook is not recorded in this context; skip this optional step'
        $text | Should -Match 'The SQL Estate workbook is not recorded in this context; skip its steps in this chapter'
        $context.machineIntelligenceWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/66666666-6666-6666-6666-666666666666"
        $context.complianceWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/77777777-7777-7777-7777-777777777777"
        $context.assetInventoryWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/88888888-8888-8888-8888-888888888888"
        $context.sqlEstateWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/99999999-9999-9999-9999-999999999999"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match '\[the Machine Intelligence Center workbook\]\(https://portal.azure.com/.*66666666-6666-6666-6666-666666666666\)'
        $text | Should -Match '\[the Compliance, Security and Governance workbook\]\(https://portal.azure.com/.*77777777-7777-7777-7777-777777777777\)'
        $text | Should -Match '\[the Asset Inventory workbook\]\(https://portal.azure.com/.*88888888-8888-8888-8888-888888888888\)'
        $text | Should -Match '\[the SQL Estate workbook, SQL under one view\]\(https://portal.azure.com/.*99999999-9999-9999-9999-999999999999\)'
        $text | Should -Not -Match '\{\{|\}\}'
    }

    It 'rejects a wrong-type link for the Asset Inventory and SQL Estate workbooks' -ForEach @(
        @{ Field = 'assetInventoryWorkbookResourceId' }
        @{ Field = 'sqlEstateWorkbookResourceId' }
    ) {
        $context[$Field] = "$scope/providers/Microsoft.Compute/virtualMachines/not-a-workbook"
        $context | ConvertTo-Json | Set-Content $path
        { & $generator -ContextPath $path } | Should -Throw '*expected resource type*'
        Test-Path $output | Should -BeFalse
    }

    It 'names the SQL host in the story only for a verified real SQL workload' {
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'the SQL host \(the machine whose \*\*Role\*\* is \*\*sql\*\*\)'
        $context.sqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/sql-fixture"
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
        $text | Should -Match 'the SQL host \*\*sql-fixture\*\*'
        $text | Should -Not -Match 'the machine whose \*\*Role\*\*'
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

    It 'can write absolute file links for a guide that is copied away from the worktree' {
        $companion = Join-Path $TestDrive 'companion folder\afternoon (guide).md'
        New-Item -ItemType Directory -Path (Split-Path $companion) -Force | Out-Null
        Set-Content $companion '# SRE fixture'
        $context.companionSreRunsheetPath = $companion
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path -AbsoluteLocalLinks | Out-Null
        $text = Get-Content $output -Raw
        $match = [regex]::Match($text, '\[SRE presenter guide\]\((file:///[^)]+)\)')
        $match.Success | Should -BeTrue
        $match.Groups[1].Value | Should -Match '^file:///[^\\]+/companion%20folder/afternoon%20%28guide%29\.md$'
        [uri]::UnescapeDataString($match.Groups[1].Value) | Should -Match 'afternoon \(guide\)\.md$'
    }

    It 'writes an absolute link to the saved SQL proof only when asked' {
        $context.sqlMachineResourceId = "$scope/providers/Microsoft.HybridCompute/machines/sql-fixture"
        $context | ConvertTo-Json | Set-Content $path
        @{
            schemaVersion = 1; workload = 'arc-sql-engine'; action = 'Status'; resourceId = $context.sqlMachineResourceId
            evidence = @{
                status = 'pass'; instance = 'ARCDEMO'; database = 'ArcDemoOrders'; edition = 'Developer Edition (64-bit)'
                version = '16.0.1000.6'; orderCount = 7; checkedAtUtc = '2026-10-20T01:02:03Z'; lastCommitUtc = '2026-10-20T01:01:53Z'
            }
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $local 'sql-engine-status.json')
        & $generator -ContextPath $path | Out-Null
        Get-Content $output -Raw | Should -Match '\[Saved engine/query proof\]\(sql-engine-status\.json\)'
        & $generator -ContextPath $path -AbsoluteLocalLinks | Out-Null
        Get-Content $output -Raw | Should -Match '\[Saved engine/query proof\]\(file:///[^)\\]+/sql-engine-status\.json\)'
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

Describe 'Presenter runsheet template' {
    BeforeAll {
        $template = Get-Content (Join-Path $repo 'docs\runsheet.md') -Raw
        $split = $template -split '(?m)^## Operator notes'
        $presenter = $split[0]
        $notes = $split[1]
        # Phrases wrap across lines and blockquote markers, so phrase assertions use flattened text.
        $flat = ($template -replace '(?m)^\s*>\s?', '') -replace '\s+', ' '
        $lines = $template -split '\r?\n'
        $spoken = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\*\*(Say|Read aloud):\*\*\s*$') {
                $label = $Matches[1]
                $j = $i + 1
                while ($j -lt $lines.Count -and $lines[$j] -eq '') { $j++ }
                $buffer = @()
                while ($j -lt $lines.Count -and $lines[$j] -match '^> ?') { $buffer += ($lines[$j] -replace '^> ?', ''); $j++ }
                $text = $buffer -join ' '
                $spoken.Add([pscustomobject]@{ Label = $label; Words = @($text -split '\s+' | Where-Object { $_ }).Count; Text = $text })
            }
        }
        $sections = @([regex]::Split($template, '(?m)^(?=## )') | Where-Object { $_ -match '^## ' })
        $chapters = @($sections | Where-Object { $_ -match '^## Chapter \d\.' })
    }

    It 'is one story: an opening, seven chapters and a close, with times that fit 25-28 minutes' {
        $rows = [regex]::Matches($template, '(?m)^\| (Opening|[1-7]|Close) \| ([^|]+) \| (\d+) \| (\d+) \| (\d+) \|\s*$')
        $rows.Count | Should -Be 9
        $full = ($rows | ForEach-Object { [int]$_.Groups[3].Value } | Measure-Object -Sum).Sum
        $twenty = ($rows | ForEach-Object { [int]$_.Groups[4].Value } | Measure-Object -Sum).Sum
        $fifteen = ($rows | ForEach-Object { [int]$_.Groups[5].Value } | Measure-Object -Sum).Sum
        $full | Should -BeGreaterOrEqual 25
        $full | Should -BeLessOrEqual 28
        $twenty | Should -BeGreaterOrEqual 17
        $twenty | Should -BeLessOrEqual 20
        $fifteen | Should -BeGreaterOrEqual 13
        $fifteen | Should -BeLessOrEqual 15
        $flat | Should -Match "add up to $full,"
        $flat | Should -Match "The 20-minute version is $twenty minutes of content and the 15-minute version is $fifteen,"
        $flat | Should -Match 'Allow \*\*25-28 minutes\*\*'
    }

    It 'puts every chapter on a continuous clock that matches the timing table' {
        $rows = @([regex]::Matches($template, '(?m)^\| (Opening|[1-7]|Close) \| ([^|]+) \| (\d+) \| (\d+) \| (\d+) \|\s*$'))
        $clock = 0
        foreach ($row in $rows | Where-Object { $_.Groups[1].Value -ne 'Close' }) {
            $key = $row.Groups[1].Value
            $title = $row.Groups[2].Value.Trim()
            $heading = if ($key -eq 'Opening') {
                [regex]::Match($template, '(?m)^## Opening: ([^\r\n(]+?) \((\d+) minutes?, clock (\d+):00 to (\d+):00\)')
            } else {
                [regex]::Match($template, "(?m)^## Chapter $key\. ([^\r\n(]+?) \((\d+) minutes?, clock (\d+):00 to (\d+):00\)")
            }
            $heading.Success | Should -BeTrue -Because "chapter $key needs a heading with minutes and clock"
            $heading.Groups[1].Value.Trim() | Should -Be $title -Because "chapter $key title must match the timing table"
            [int]$heading.Groups[2].Value | Should -Be ([int]$row.Groups[3].Value) -Because "chapter $key minutes"
            [int]$heading.Groups[3].Value | Should -Be $clock -Because "chapter $key must start where the previous one ended"
            $clock += [int]$row.Groups[3].Value
            [int]$heading.Groups[4].Value | Should -Be $clock -Because "chapter $key end"
        }
        $close = $rows | Where-Object { $_.Groups[1].Value -eq 'Close' }
        $template | Should -Match "(?m)^## The close: [^\r\n(]+ \($($close.Groups[3].Value) minutes\)"
    }

    It 'gives every chapter the same shape: question, thread, things to show, words to say, a wow and a watch-outs box' {
        $chapters.Count | Should -Be 7
        foreach ($section in $chapters) {
            $name = ($section -split '\r?\n')[0]
            $section | Should -Match "(?m)^> \*\*The customer's question:\*\* " -Because $name
            $section | Should -Match '(?m)^> \*\*The thread:\*\* ' -Because $name
            $section | Should -Match '(?m)^\*\*Show, in this order:\*\*' -Because $name
            $section | Should -Match '(?m)^\*\*Say:\*\*' -Because $name
            $section | Should -Match '(?m)^\*\*Wow:\*\* ' -Because $name
            $section | Should -Match '(?m)^> \*\*Watch-outs / if asked\*\*' -Because $name
            $show = [regex]::Match($section, '(?s)\*\*Show, in this order:\*\*(.*?)\*\*Say:\*\*').Groups[1].Value
            $items = [regex]::Matches($show, '(?m)^\d\. ').Count
            $items | Should -BeGreaterOrEqual 2 -Because "$name shows 2 to 4 things"
            $items | Should -BeLessOrEqual 4 -Because "$name shows 2 to 4 things"
        }
    }

    It 'keeps every spoken block short enough to say in about 45 seconds' {
        $spoken.Count | Should -BeGreaterOrEqual 10
        foreach ($block in $spoken) {
            $limit = if ($block.Label -eq 'Read aloud') { 115 } else { 120 }
            $block.Words | Should -BeLessOrEqual $limit -Because $block.Text.Substring(0, 50)
        }
    }

    It 'bridges the opening and chapters 1 to 6 into the next with one short sentence, and chapter 7 into the hand-over' {
        $bridges = @([regex]::Matches($template, '(?m)^\*\*Bridge:\*\* (.+(?:\r?\n(?!\r?\n).+)*)'))
        $bridges.Count | Should -Be 7
        foreach ($bridge in $bridges) {
            $words = @(($bridge.Groups[1].Value -replace '\s+', ' ').Split(' ')).Count
            $words | Should -BeLessOrEqual 30 -Because $bridge.Groups[1].Value
        }
        $template | Should -Match '(?m)^## Hand over to the SRE half'
    }

    It 'asks the room three or four times and gives each chapter one wow moment' {
        [regex]::Matches($template, '(?m)^\*\*Ask the room:\*\*').Count | Should -BeGreaterOrEqual 3
        [regex]::Matches($template, '(?m)^\*\*Ask the room:\*\*').Count | Should -BeLessOrEqual 4
        [regex]::Matches($template, '(?m)^\*\*Wow:\*\* ').Count | Should -Be 7
    }

    It 'follows one database from the opening to the alert and the hand-over' {
        $flat | Should -Match 'the orders database, from ''what is it\?'' to ''what wakes us at night\?'''
        foreach ($section in $chapters) { $section | Should -Match 'orders database|SQL host|lock-timeout rule' -Because (($section -split '\r?\n')[0]) }
        $flat | Should -Match 'The orders database we started with is about to have a bad night, on purpose, and you''ll watch what happens between the alert and a person making a decision'
        $flat | Should -Match 'a person decided what, if anything, changed'
    }

    It 'covers the three engineer tasks and the reader versus approver boundary' {
        $flat | Should -Match '\| 1\. Find a server or workload and see whether its data is current \| Chapters 1 and 2 \|'
        $flat | Should -Match '\| 2\. Open the capacity or optimisation view and drill into the evidence \| Chapters 5 and 6 \|'
        $flat | Should -Match '\| 3\. Open an incident, read the investigation and review a narrowly scoped proposed action \| Chapter 7, then the SRE guide \|'
        $flat | Should -Match 'Reader and approver are separate roles'
    }

    It 'puts Windows, Linux and SQL under one view, including the experimental nested Arc SQL boundary' {
        $template | Should -Match '(?m)^## Chapter 2\. Show me one server'
        $template | Should -Match '(?m)^## Chapter 4\. What about the database\?'
        $template | Should -Match '\{\{SqlEstateAvailability\}\}'
        $template | Should -Match '\{\{NestedSqlAvailability\}\}'
        $template | Should -Match '\{\{SqlAvailability\}\}'
        $flat | Should -Match 'license-only mode'
        $flat | Should -Match 'not a supported Arc SQL configuration'
        $flat | Should -Match 'Do not claim Monitoring, best practices assessment or Defender for SQL'
        $flat | Should -Match 'old evidence or SQL-shaped simulator events do not prove a running engine today'
    }

    It 'presents both workbooks as the engineer lens' {
        $template | Should -Match '(?m)^## Chapter 5\. Do we have room for what is next\?'
        $template | Should -Match '(?m)^## Chapter 6\. Where is the money going\?'
        $template | Should -Match '\{\{CapacityWorkbookAvailability\}\}'
        $template | Should -Match '\{\{OptimisationWorkbookAvailability\}\}'
    }

    It 'hands the SQL and application alert chapter to the SRE guide in neutral wording' {
        $template | Should -Match '(?m)^## Chapter 7\. What happens at 2 a\.m\.\?'
        $template | Should -Match '\{\{SqlIncidentAvailability\}\}'
        $template | Should -Match '\{\{LobIncidentAvailability\}\}'
        $template | Should -Match '(?m)^## Hand over to the SRE half\r?\n\r?\n\{\{CompanionSection\}\}'
        $flat | Should -Match 'incidents are triggered, approved and read in the SRE half'
        $flat | Should -Match 'These alerts use the same action group\. When the SQL worker logs a lock timeout, or the application worker reports a degraded state, an alert fires and the SRE agent starts an investigation automatically\. The incidents we walk through next are the SRE agent''s own: any we trigger live are current, earlier ones are dated'
        $template | Should -Not -Match '(?i)\bprobe\b'
    }

    It 'keeps operator mechanics out of the presenter path' {
        $notes | Should -Match 'bounded lock-timeout helper'
        $presenter | Should -Not -Match 'bounded lock-timeout helper|Test-ArcDemoReadiness|Test-ArcSqlDemoInventory|Invoke-SqlEngineOnArc'
    }

    It 'sets the stage first: workbooks opened from the gallery in their own tabs, and grids that fit the screen' {
        $stage = @($sections | Where-Object { $_ -match '^## Stage setup' })
        $stage.Count | Should -Be 1
        $stageFlat = ($stage[0] -replace '(?m)^\s*>\s?', '') -replace '\s+', ' '
        $stageFlat | Should -Match 'Open every workbook from the gallery, each in its own tab'
        $stageFlat | Should -Match 'shows its display name in the title; one opened by a direct link shows its ID'
        $stageFlat | Should -Match 'The links in this guide are the fallback, not the way in'
        $stageFlat | Should -Match 'browser zoom to 100 percent \(90 percent on a smaller screen\)'
        $stageFlat | Should -Match "collapse the portal's left menu, press F11 for full screen and hide the favourites bar"
        $stage[0] | Should -Match '\{\{workspaceUrl\}\}'
        $notes | Should -Match 'Workbooks gallery'
        $template.IndexOf('## Stage setup') | Should -BeLessThan $template.IndexOf('## Opening:')
    }

    It 'no longer carries statements that are wrong for the demo as it is' {
        $template | Should -Not -Match 'not part of this default demo'
        $template | Should -Not -Match 'one-shot probe'
        $template | Should -Not -Match '20-30 minutes|25-30 minutes'
        $template | Should -Not -Match 'OperationalWorkbookSection'
        $template | Should -Not -Match '(?i)\bscenes?\b'
        $template | Should -Not -Match 'empty by design'
    }

    It 'keeps the read-only presenter behaviour and the honesty caveats' {
        $flat | Should -Match 'Everything on this Arc path is read-only: do not start machines, run assessments, select \*\*Check for updates\*\*'
        $flat | Should -Match 'Live faults, fresh investigations and the Review approval belong to the SRE half'
        $flat | Should -Match 'not a hardened production architecture'
        $flat | Should -Match 'Missing data is not zero'
        $flat | Should -Match 'never additive hardware capacity'
        $flat | Should -Match 'not billing, not realised savings'
        $flat | Should -Match 'Update Manager is free for Azure VMs but billed for Arc-enabled servers'
        $flat | Should -Match 'we make no Defender claim for an experimental nested guest'
        $flat | Should -Match 'A stale or non-reporting machine is not safe to delete or redundant'
        $flat | Should -Match 'there''s no delete button, and nothing here changes a server'
    }

    It 'describes the Compliance patch tiles as Update Manager data, not a connection-state estimate' {
        $template | Should -Not -Match 'heuristic'
        $template | Should -Not -Match 'Do not read out the workbook'
        $flat | Should -Match 'read the latest Update Manager assessments'
        $flat | Should -Match 'never counted as \*\*Fully patched\*\*'
        $flat | Should -Match '\*\*Assessment failed\*\* or \*\*Not assessed\*\*'
        $flat | Should -Match 'Stand behind the \*\*Policy compliance\*\* figure for governance'
        $flat | Should -Match 'the \*\*Updates\*\* view above is the per-machine drill-down'
    }

    It 'names the agent and the data collection rule without a cost claim' {
        $flat | Should -Match 'The Azure Monitor Agent collects the telemetry'
        $flat | Should -Match 'control plane'
        $flat | Should -Match 'nothing is collected twice'
        $flat | Should -Match 'say nothing about cost savings'
        $flat | Should -Match 'Linux hosts get it, and Change Tracking, as Azure VM extensions'
    }

    It 'prepares answers for the two pain points it does not demonstrate' {
        $template | Should -Match '(?m)^### Disaster recovery \(pain point 4, not demonstrated\)'
        $template | Should -Match '(?m)^### Migration and modernisation \(pain point 6, evidence only\)'
        $flat | Should -Match 'Disaster recovery isn''t part of this demonstration, and Arc doesn''t provide it'
        $flat | Should -Match 'hibernating this lab is a cost action, not disaster recovery'
        $flat | Should -Match 'none of these views is one: no readiness score, no target sizing, no migration cost'
        $flat | Should -Match 'Moving a workload is optional; Arc improves how you manage it where it is'
        $flat | Should -Match '\*\*Why two agents\?\*\* Arc is not a telemetry agent'
        $flat | Should -Match '\*\*Private link\?\*\* The agent needs a data collection endpoint added to an Azure Monitor Private Link Scope'
    }

    It 'closes by mapping every pain point to what was seen, with one next step' {
        $close = ($sections | Where-Object { $_ -match '^## The close:' }) -join ''
        $close | Should -Not -BeNullOrEmpty
        [regex]::Matches($close, '(?m)^\| [1-8] [A-Z][^|]+ \| ').Count | Should -Be 8
        $close | Should -Match '(?m)^\*\*Next step:\*\* choose one group of servers'
        $close | Should -Match '\| 4 Disaster recovery \| Not part of this demonstration \| Prepared answer \|'
    }

    It 'keeps counts out of the story, because they move as the lab runs' {
        $presenter | Should -Not -Match '\b\d+ of \d+\b'
        $presenter | Should -Not -Match '\b\d+(\.\d+)? ?%'
        $presenter | Should -Not -Match '(?i)\b(?:nine|eight|seven|six|five|three) (?:machines|servers|hosts)\b'
        $presenter | Should -Not -Match '(?i)about \d+ (?:machines|servers|hosts|instances)'
    }

    It 'contains no private identifier, customer name or internal-only citation' {
        $template | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $template | Should -Not -Match '(?i)internal only|strictly ms|ama q&a'
        $template | Should -Not -Match 'C:\\|@microsoft\.com'
        $template | Should -Not -Match '\bDTF\b|(?i)treasury'
        $template | Should -Match '^[\x00-\x7F]*$' -Because 'the template is plain ASCII so the generated guide never shows mangled punctuation'
    }
}
