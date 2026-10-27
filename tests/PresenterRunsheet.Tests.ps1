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
