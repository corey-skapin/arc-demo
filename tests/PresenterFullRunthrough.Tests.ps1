BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $generator = Join-Path $repo 'scripts\New-PresenterRunsheet.ps1'

    function Get-DocHeading([string]$Text, [int[]]$Level = @(1, 2)) {
        $fenced = $false
        foreach ($line in ($Text -split '\r?\n')) {
            if ($line -match '^\s*(```|~~~)') { $fenced = -not $fenced; continue }
            if (-not $fenced -and $line -match '^(#{1,6}) (.+?)\s*$' -and $Matches[1].Length -in $Level) {
                [pscustomobject]@{ Level = $Matches[1].Length; Text = $Matches[2] }
            }
        }
    }
    function Get-Slug([string]$Heading) { '#' + (($Heading.ToLowerInvariant() -replace '[^\p{L}\p{N}\s_-]', '') -replace '\s', '-') }

    # The shape of the real generated SRE guide, with fixture names only: nested headings, a heading-looking line inside a code
    # fence, a command, a thread reference and a close that repeats the Arc close.
    $script:SreGuide = @'
# SRE demo: investigate, review, verify

## This afternoon: verified existing investigations

Read-only verification text. Thread 00000000-aaaa-bbbb-cccc-000000000001 is the first existing investigation.

## Live faults

Say **GO** only after the alert rules are shown. The assistant runs `Invoke-SreDemoRoute.ps1 -Action Prepare` for `SQL`.

## 1. Pick up from Arc

Complete the Arc section first, then continue here.

## 2. Show the healthy Container App

Open the application and check the revision.

## 3. Show the configured response

Inspect the response plans without editing.

## 4. Walk through an existing investigation

Open the original completed report.

## 5. Live SQL and LOB investigations

Run SQL first, then LOB.

### Optional reference: bounded manual LOB query

```text
## 3. a heading-looking line inside a code fence is code
Tenant: 00000000-0000-0000-0000-000000000000
```

### SQL: alert-driven investigation of a real lock timeout

Match alert ID, timestamp and host.

## 6. Live T09: human-reviewed Container App repair

The signed-in human approves only the current run's reset card.

## 7. Close

Return to the application.

**Say:** "Back to Monday morning. Fixture SRE closing words that the combined guide must not repeat."
'@

    $script:NewFixture = {
        $local = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '\.local')
        New-Item -ItemType Directory -Path $local -Force | Out-Null
        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture'
        @{
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
        } | ConvertTo-Json | Set-Content (Join-Path $local 'demo-context.json')
        $local
    }
}

Describe 'Whole-demo run-through: Arc, the SRE half and one close' {
    BeforeEach {
        $local = & $script:NewFixture
        $path = Join-Path $local 'demo-context.json'
        $arcOutput = Join-Path $local 'presenter-runsheet.md'
        $fullOutput = Join-Path $local 'full-demo-runsheet.md'
        $sreGuide = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '-sre-guide.md')
        Set-Content -LiteralPath $sreGuide -Value $script:SreGuide -Encoding utf8 -NoNewline
        Mock Invoke-RestMethod { throw 'Offline generation must not query Azure.' }
        Mock Start-Process { throw 'Offline generation must not launch tools.' }
    }

    It 'writes the combined page only when an SRE guide is given, and leaves the Arc guide as it was' {
        $plain = & $generator -ContextPath $path
        $plain.PSObject.Properties.Name | Should -Not -Contain 'FullDemoPath'
        Test-Path $fullOutput | Should -BeFalse
        $arcOnly = (Get-Content $arcOutput -Raw) -replace '\*\*\d{4}-\d{2}-\d{2}T[\d:.]+Z\*\*', '**stamp**'

        $result = & $generator -ContextPath $path -SreGuidePath $sreGuide
        $result.Path | Should -Be $arcOutput
        $result.FullDemoPath | Should -Be $fullOutput
        $result.AzureQueried | Should -BeFalse
        Test-Path $fullOutput | Should -BeTrue
        ((Get-Content $arcOutput -Raw) -replace '\*\*\d{4}-\d{2}-\d{2}T[\d:.]+Z\*\*', '**stamp**') | Should -Be $arcOnly
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'shows every Arc chapter heading and every SRE step heading once, in order, with the SRE half between the hand over and the close' {
        $arcResult = & $generator -ContextPath $path -SreGuidePath $sreGuide
        $arc = @(Get-DocHeading (Get-Content $arcOutput -Raw) 2 | ForEach-Object Text)
        $combined = @(Get-DocHeading (Get-Content $fullOutput -Raw) 2 | ForEach-Object Text) | Where-Object { $_ -ne 'Whole demo in order' }
        $handOver = [array]::IndexOf($arc, 'Hand over to the SRE half')
        $handOver | Should -BeGreaterThan 0
        $sre = @('This afternoon: verified existing investigations', 'Live faults',
            'SRE step 1. Pick up from Arc', 'SRE step 2. Show the healthy Container App', 'SRE step 3. Show the configured response',
            'SRE step 4. Walk through an existing investigation', 'SRE step 5. Live SQL and LOB investigations',
            'SRE step 6. Live T09: human-reviewed Container App repair', 'SRE step 7. Close')
        $expected = @($arc[0..$handOver]) + $sre + @($arc[($handOver + 1)..($arc.Count - 1)])
        $combined | Should -Be $expected
        @($combined | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
        @($combined | Where-Object { $_ -like 'Chapter *' }).Count | Should -Be 7
        $combined[$combined.IndexOf('SRE step 7. Close') + 1] | Should -Match '^The close: the Monday answers'
    }

    It 'splits the page into three named parts: the Arc guide, the night shift, then the close and reference' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        @(Get-DocHeading (Get-Content $fullOutput -Raw) 1 | ForEach-Object Text) | Should -Be @(
            'Full demo run-through: from servers to the night shift'
            'Arc: from servers to an operational view'
            'The night shift (SRE half)'
            'The close, prepared answers and reference'
        )
    }

    It 'keeps the SRE text byte for byte and renames only the numbered step headings' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        $text = Get-Content $fullOutput -Raw
        $start = $script:SreGuide.IndexOf('## This afternoon: verified existing investigations')
        $end = $script:SreGuide.IndexOf('## 7. Close')
        $expected = $script:SreGuide.Substring($start, $end - $start)
        $titles = @{
            1 = 'Pick up from Arc'; 2 = 'Show the healthy Container App'; 3 = 'Show the configured response'
            4 = 'Walk through an existing investigation'; 5 = 'Live SQL and LOB investigations'; 6 = 'Live T09: human-reviewed Container App repair'
        }
        foreach ($number in 1..6) { $expected = $expected.Replace("## $number. $($titles[$number])", "## SRE step $number. $($titles[$number])") }
        $text.Contains($expected) | Should -BeTrue
        $text | Should -Match 'Invoke-SreDemoRoute\.ps1 -Action Prepare'
        $text | Should -Match '00000000-aaaa-bbbb-cccc-000000000001'
        $text | Should -Match '(?m)^## 3\. a heading-looking line inside a code fence is code'
        $text | Should -Not -Match '(?m)^## SRE step 3\. a heading-looking'
        $text | Should -Match '(?m)^### Optional reference: bounded manual LOB query'
        $text | Should -Match '(?m)^### SQL: alert-driven investigation of a real lock timeout'
    }

    It 'gives the close once: the SRE close is a pointer to the Arc close' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        $text = Get-Content $fullOutput -Raw
        ([regex]::Matches($text, 'Back to Monday morning\.')).Count | Should -Be 1
        $text | Should -Not -Match 'Fixture SRE closing words'
        @(Get-DocHeading $text 2 | Where-Object Text -like 'The close:*').Count | Should -Be 1
        $step = [regex]::Match($text, '(?ms)^## SRE step 7\. Close\r?\n\r?\n(?<body>.*?)\r?\n\r?\n# The close, prepared answers and reference')
        $step.Success | Should -BeTrue
        $step.Groups['body'].Value | Should -Not -Match '\r?\n'
        $step.Groups['body'].Value | Should -Match '^Close with \[The close: the Monday answers\]\(#the-close-the-monday-answers-2-minutes\) below'
    }

    It 'builds a whole-demo table from the chapter clock times, with a working link per row and the live-fault points' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        $text = Get-Content $fullOutput -Raw
        $table = [regex]::Match($text, '(?ms)^## Whole demo in order\r?\n\r?\n(?<rows>\|.*?)\r?\n\r?\n').Groups['rows'].Value -split '\r?\n'
        $table[0] | Should -Be '| Clock | Chapter or step | Live-fault point |'
        $slugs = @(Get-DocHeading $text 1, 2, 3, 4 | ForEach-Object { Get-Slug $_.Text })
        $links = @([regex]::Matches(($table -join "`n"), '\]\((#[^)]+)\)') | ForEach-Object { $_.Groups[1].Value })
        $links.Count | Should -Be 17
        foreach ($link in $links) { $link | Should -BeIn $slugs }
        $clocks = @($table[2..9] | ForEach-Object { ($_ -split '\|')[1].Trim() })
        $clocks | Should -Be @('0:00 to 1:00', '1:00 to 4:00', '4:00 to 8:00', '8:00 to 11:00', '11:00 to 14:00', '14:00 to 17:00', '17:00 to 20:00', '20:00 to 23:00')
        $chapterSeven = $table | Where-Object { $_ -like '*Chapter 7.*' }
        $chapterSeven | Should -Match '\*\*Say GO\*\* once the alert rules are shown'
        $chapterSeven | Should -Match '\*\*Prepare\*\*'
        ($table | Where-Object { $_ -like '*Hand over to the SRE half*' }) | Should -Match '^\| 23:00 \|'
        ($table | Where-Object { $_ -like '*SRE step 5.*' }) | Should -Match '\*\*Fire SQL\*\*.*\*\*fire LOB\*\*'
        ($table | Where-Object { $_ -like '*SRE step 6.*' }) | Should -Match '\*\*Fire T09\.\*\*.*\*\*Review\*\* click'
        ($table | Where-Object { $_ -like '*Live faults*' }) | Should -Match '\*\*Restore\*\*.*-Action Restore'
        ($table | Select-Object -Last 1) | Should -Match 'The close: the Monday answers'
        $table.Count | Should -Be 19
    }

    It 'fills every token, keeps the Stage setup lines and sends the hand over to the section below, not a second guide' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        $text = Get-Content $fullOutput -Raw
        $text | Should -Not -Match '\{\{|\}\}'
        $text | Should -Match 'Open every workbook from the gallery'
        $text | Should -Match '\[The night shift \(SRE half\)\]\(#the-night-shift-sre-half\) below'
        $text | Should -Not -Match '\[SRE presenter guide\]'
        $crlf = ([regex]::Matches($text, '\r\n')).Count
        $lf = ([regex]::Matches($text, '\n')).Count
        ($crlf -eq 0 -or $crlf -eq $lf) | Should -BeTrue -Because 'the page keeps one line-ending style'
    }

    It 'refuses a relative path, a missing file and a guide that is not shaped like the SRE guide, and writes nothing' {
        { & $generator -ContextPath $path -SreGuidePath 'sre-guide.md' } | Should -Throw '*explicit absolute local path*'
        { & $generator -ContextPath $path -SreGuidePath (Join-Path $TestDrive 'absent-sre-guide.md') } | Should -Throw '*was not found*'
        $cases = @{
            'a missing step' = ($script:SreGuide -replace '(?m)^## 3\. ', '## Three. ')
            'steps out of order' = ($script:SreGuide -replace '(?m)^## 2\. ', '## 9. ' -replace '(?m)^## 3\. ', '## 2. ' -replace '(?m)^## 9\. ', '## 3. ')
            'no Live faults' = ($script:SreGuide -replace '(?m)^## Live faults', '## Faults')
            'a repeated step' = ($script:SreGuide + "`n## 6. Live T09 again`n")
            'a different close' = ($script:SreGuide -replace '(?m)^## 7\. Close', '## 7. Wrap up')
            'step headings only inside a code fence' = ($script:SreGuide -replace '(?ms)^## 4\. .*?(?=^## 5\. )', ('```text' + "`n## 4. Walk through an existing investigation`n" + '```' + "`n`n"))
        }
        foreach ($case in $cases.GetEnumerator()) {
            $broken = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '-broken-sre-guide.md')
            Set-Content -LiteralPath $broken -Value $case.Value -Encoding utf8 -NoNewline
            { & $generator -ContextPath $path -SreGuidePath $broken } | Should -Throw '*does not have the expected shape*' -Because $case.Key
        }
        Test-Path $arcOutput | Should -BeFalse
        Test-Path $fullOutput | Should -BeFalse
    }

    It 'never changes the SRE guide it reads' {
        $before = (Get-FileHash -LiteralPath $sreGuide -Algorithm SHA256).Hash
        & $generator -ContextPath $path -SreGuidePath $sreGuide | Out-Null
        (Get-FileHash -LiteralPath $sreGuide -Algorithm SHA256).Hash | Should -Be $before
    }

    It 'previews with -WhatIf without writing either page' {
        & $generator -ContextPath $path -SreGuidePath $sreGuide -WhatIf | Out-Null
        Test-Path $arcOutput | Should -BeFalse
        Test-Path $fullOutput | Should -BeFalse
    }
}

Describe 'Whole-demo run-through template contract' {
    BeforeAll {
        $template = Get-Content (Join-Path $repo 'docs\runsheet.md') -Raw
    }

    It 'names both generated pages in its Presenter line' {
        $template | Should -Match '\.local/presenter-runsheet\.md'
        $template | Should -Match '\.local/full-demo-runsheet\.md'
    }

    It 'keeps the headings the combined page is spliced and tabled from' {
        $headings = @(Get-DocHeading $template 2 | ForEach-Object Text)
        $handOver = $headings.IndexOf('Hand over to the SRE half')
        $handOver | Should -BeGreaterThan 0
        $headings[$handOver + 1] | Should -Be 'The close: the Monday answers (2 minutes)'
        @($headings | Where-Object { $_ -match '^(Opening: .+|Chapter \d\. .+) \(\d+ minutes?, clock \d+:\d\d to \d+:\d\d\)$' }).Count | Should -Be 8
    }
}
