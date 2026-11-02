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

    It 'skips the nested scene, links and incident rules plainly when they are not recorded' {
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match 'No nested Arc SQL guest is recorded in this context; skip scene 3b'
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
        $text | Should -Match 'The Machine Intelligence Center workbook is not recorded in this context; skip this optional step'
        $text | Should -Match 'The compliance workbook is not recorded in this context; skip this optional step'
        $context.machineIntelligenceWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/66666666-6666-6666-6666-666666666666"
        $context.complianceWorkbookResourceId = "$scope/providers/Microsoft.Insights/workbooks/77777777-7777-7777-7777-777777777777"
        $context | ConvertTo-Json | Set-Content $path
        & $generator -ContextPath $path | Out-Null
        $text = Get-Content $output -Raw
        $text | Should -Match '\[the Machine Intelligence Center workbook\]\(https://portal.azure.com/.*66666666-6666-6666-6666-666666666666\)'
        $text | Should -Match '\[the Compliance, Security and Governance workbook\]\(https://portal.azure.com/.*77777777-7777-7777-7777-777777777777\)'
        $text | Should -Not -Match '\{\{|\}\}'
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
    }

    It 'is one coherent Arc path whose scene times fit 25-30 minutes' {
        $rows = [regex]::Matches($template, '(?m)^\| (\d) \| .+ \| (\d+) \| .+ \|\s*$')
        $rows.Count | Should -Be 8
        $total = ($rows | ForEach-Object { [int]$_.Groups[2].Value } | Measure-Object -Sum).Sum
        $total | Should -BeGreaterOrEqual 25
        $total | Should -BeLessOrEqual 30
        $template | Should -Match "add up to $total[;)]"
        $template | Should -Match 'Allow \*\*25-30 minutes\*\*'
    }

    It 'covers the three engineer tasks and the reader versus approver boundary' {
        $template | Should -Match 'Engineer task 1:\*\* find a server or workload and see whether its data is current'
        $template | Should -Match 'Engineer task 2:\*\* open the capacity view and drill into the evidence'
        $template | Should -Match 'Engineer task 3 starts here:\*\* open an incident, read the investigation and\s+review a narrowly scoped proposed action'
        $template | Should -Match 'Reader and approver are separate roles'
    }

    It 'puts Windows, Linux and SQL under one view, including the experimental nested Arc SQL scene' {
        $template | Should -Match '(?m)^## 2\. Find a server and check its data is current'
        $template | Should -Match '(?m)^### 3a\. A real SQL workload observed by Azure Monitor'
        $template | Should -Match '(?m)^### 3b\. Nested Arc-enabled SQL Server, experimental'
        $template | Should -Match 'license-only mode'
        $template | Should -Match 'not a supported Arc SQL configuration'
        $template | Should -Match 'Do not claim Monitoring, best practices assessment or Defender for SQL'
    }

    It 'presents both workbooks as the engineer lens' {
        $template | Should -Match '(?m)^## 4\. Capacity and headroom'
        $template | Should -Match '(?m)^## 5\. Optimisation opportunities'
        $template | Should -Match '\{\{CapacityWorkbookAvailability\}\}'
        $template | Should -Match '\{\{OptimisationWorkbookAvailability\}\}'
    }

    It 'hands the SQL and application alert scenes to the SRE guide in neutral wording' {
        $template | Should -Match '(?m)^### 6c\. The SQL and application alerts'
        $template | Should -Match '\{\{SqlIncidentAvailability\}\}'
        $template | Should -Match '\{\{LobIncidentAvailability\}\}'
        $template | Should -Match 'incidents are\s+triggered, approved and read in the SRE half'
        $template | Should -Not -Match '(?i)\bprobe\b'
    }

    It 'keeps operator mechanics out of the presenter path' {
        $notes | Should -Match 'bounded lock-timeout helper'
        $presenter | Should -Not -Match 'bounded lock-timeout helper|Test-ArcDemoReadiness|Test-ArcSqlDemoInventory|Invoke-SqlEngineOnArc'
    }

    It 'no longer carries statements that are wrong for the demo as it is' {
        $template | Should -Not -Match 'not part of this default demo'
        $template | Should -Not -Match 'one-shot probe'
        $template | Should -Not -Match '20-30 minutes'
        $template | Should -Not -Match 'OperationalWorkbookSection'
    }

    It 'keeps the read-only presenter behaviour and the honesty caveats' {
        $template | Should -Match 'Everything on this Arc path is\s+read-only'
        $template | Should -Match 'do not start machines, run\s+assessments, select \*\*Check for updates\*\*'
        $template | Should -Match 'not a hardened production architecture'
        $template | Should -Match 'Missing data is not zero'
        $template | Should -Match 'never additive hardware capacity'
        $template | Should -Match 'not billing, not realised savings'
        $template | Should -Match 'Update Manager is free for Azure VMs\s+but billed for Arc-enabled servers'
        $template | Should -Match 'we make no Defender claim\s+for an experimental nested\s+guest'
    }

    It 'describes the Compliance patch tiles as Update Manager data, not a connection-state estimate' {
        $template | Should -Not -Match 'heuristic'
        $template | Should -Not -Match 'Do not read out the workbook'
        $template | Should -Match 'read the latest Update Manager\s+assessments'
        $template | Should -Match 'never counted as\s+\*\*Fully patched\*\*'
        $template | Should -Match '\*\*Assessment failed\*\*\s+or\s+\*\*Not assessed\*\*'
        $template | Should -Match 'Stand behind that figure for governance'
        $template | Should -Match 'the \*\*Updates\*\* view above is the per-machine\s+drill-down'
    }

    It 'names the agent and the data collection rule without a cost claim' {
        $template | Should -Match 'The Azure Monitor Agent collects the telemetry'
        $template | Should -Match 'control plane'
        $template | Should -Match 'nothing is collected twice'
        $template | Should -Match 'say nothing about cost savings'
        $template | Should -Match 'Linux hosts get it, and Change\s+Tracking, as Azure VM extensions'
    }

    It 'contains no private identifier or internal-only citation' {
        $template | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $template | Should -Not -Match '(?i)internal only|strictly ms|ama q&a'
        $template | Should -Not -Match 'C:\\|@microsoft\.com'
    }
}
