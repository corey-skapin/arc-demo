BeforeDiscovery {
    # Each chapter and the workbook files whose tile, section, tab and label names it may show in bold.
    # A directory means every .kql file in it (the Capacity and Optimisation tile labels live there).
    $Chapters = @(
        @{ Number = 1; Files = @('workbooks/arc-demo-overview.workbook.json', 'workbooks/arc-asset-inventory.workbook.json') }
        @{ Number = 2; Files = @('workbooks/nseilaz/ArcMachineIntelligenceCenter.json') }
        @{ Number = 3; Files = @('workbooks/arc-compliance.workbook.json', 'workbooks/arc-governance.workbook.json') }
        @{ Number = 4; Files = @('workbooks/nseilaz/SQL_Estate_Dashboard.json') }
        @{ Number = 5; Files = @('workbooks/capacity-headroom.workbook.json', 'workbooks/queries') }
        @{ Number = 6; Files = @('workbooks/optimisation-opportunities.workbook.json', 'workbooks/queries') }
        @{ Number = 7; Files = @() }
    )
    $Known = @(@{ Numbers = @($Chapters | ForEach-Object { $_.Number }) })
}

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    $script:Template = Get-Content -LiteralPath (Join-Path $script:Repo 'docs/runsheet.md') -Raw
    $script:Sections = @([regex]::Split($script:Template, '(?m)^(?=## )') | Where-Object { $_ -match '^## ' })

    # The template wraps lines and blockquotes, so names are compared on flattened text.
    function ConvertTo-FlatText([string]$Text) { ($Text -replace '(?m)^\s*>\s?', '') -replace '\s+', ' ' }
    function Get-BoldPhrase([string]$Text) {
        @([regex]::Matches((ConvertTo-FlatText $Text), '\*\*([^*]+?)\*\*') |
                ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    }
    function Read-WorkbookText([string[]]$Paths) {
        $parts = foreach ($path in $Paths) {
            $full = Join-Path $script:Repo $path
            if (Test-Path -LiteralPath $full -PathType Container) {
                Get-ChildItem -LiteralPath $full -Filter '*.kql' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
            } else {
                Get-Content -LiteralPath $full -Raw
            }
        }
        (($parts -join ' ') -replace '\\n', ' ') -replace '\s+', ' '
    }

    # Bold that is not a workbook name: the labels of the chapter shape, deploy-time tokens, portal blades and
    # buttons the guide tells the presenter to use or avoid, and the guide's own emphasis.
    $script:Structural = "^(The customer's question|The thread|Show, in this order|Say|Wow|Ask the room|Bridge|Read aloud|Next step|Presenter):?$|^Watch-outs / if asked$"
    $script:Token = '^\{\{[A-Za-z]+\}\}$'
    $script:Portal = @(
        'Check for updates', 'Test', 'Updates', 'Last assessed', 'Overview', 'Resources', 'Data sources', 'Extensions', 'Type',
        'Logs', 'Simple mode', 'KQL mode', 'Connected', 'Disconnected', 'Expired', 'Last collected time', 'Status', 'Workbooks',
        'Settings', 'Language + region', 'Regional format', 'Apply'
    )
    $script:Emphasis = @('follow one database', 'understand', 'plan', 'prioritise', 'operate', 'close', 'Live', 'Recorded')
    function Test-NotAWorkbookName([string]$Name) {
        $Name -match $script:Structural -or $Name -match $script:Token -or $Name -in $script:Portal -or $Name -in $script:Emphasis -or
            $Name -match '^\d+(-\d+)? minutes?:?$' -or $Name -match '[.?:]$' -or $Name -match '^Stay out of$'
    }
    $script:AllWorkbookText = Read-WorkbookText @(
        'workbooks/arc-demo-overview.workbook.json', 'workbooks/arc-asset-inventory.workbook.json', 'workbooks/nseilaz/ArcMachineIntelligenceCenter.json',
        'workbooks/arc-compliance.workbook.json', 'workbooks/arc-governance.workbook.json', 'workbooks/nseilaz/SQL_Estate_Dashboard.json',
        'workbooks/capacity-headroom.workbook.json', 'workbooks/optimisation-opportunities.workbook.json', 'workbooks/queries')
}

Describe 'Every bold tile, section or tab name in a presenter chapter exists in the workbook that chapter uses' {
    It 'chapter <Number>: each bold name is a name in its workbooks, a portal name or a label of the chapter shape' -ForEach $Chapters {
        $section = @($script:Sections | Where-Object { $_ -match "^## Chapter $Number\." })
        $section.Count | Should -Be 1 -Because "the template needs exactly one chapter $Number"
        $workbook = Read-WorkbookText $Files
        foreach ($name in (Get-BoldPhrase $section[0])) {
            if (Test-NotAWorkbookName $name) { continue }
            $workbook.Contains($name) | Should -BeTrue -Because "chapter $Number names **$name** but none of [$($Files -join ', ')] contains it; fix the name or the workbook"
        }
    }

    It 'covers every chapter of the template, so a new chapter cannot be added without a guard' -ForEach $Known {
        $numbers = @([regex]::Matches($script:Template, '(?m)^## Chapter (\d)\.') | ForEach-Object { [int]$_.Groups[1].Value })
        ($numbers | Sort-Object) -join ',' | Should -Be (($Numbers | Sort-Object) -join ',')
    }

    It 'the timing and cut lists name only workbook tiles, sections or tabs that exist in some workbook' {
        $section = ($script:Sections | Where-Object { $_ -match '^## Timing and cut lists' }) -join ''
        $names = @(Get-BoldPhrase $section)
        $names.Count | Should -BeGreaterThan 3
        foreach ($name in $names) {
            if (Test-NotAWorkbookName $name) { continue }
            $script:AllWorkbookText.Contains($name) | Should -BeTrue -Because "the cut lists name **$name**, which no workbook contains"
        }
    }

    It 'the rest of the guide (ground rules, prepared answers, fallbacks) bolds no unknown tile or section name' {
        $rest = ($script:Sections | Where-Object { $_ -notmatch '^## (Chapter \d\.|Timing and cut lists|Operator notes)' }) -join "`n"
        foreach ($name in (Get-BoldPhrase $rest)) {
            if (Test-NotAWorkbookName $name) { continue }
            $script:AllWorkbookText.Contains($name) | Should -BeTrue -Because "the guide bolds **$name**, which is neither a workbook name nor a known portal or guide label"
        }
    }

    It 'no longer names tiles that the rebuilt workbooks dropped' {
        $flat = ConvertTo-FlatText $script:Template
        $flat | Should -Not -MatchExactly 'UPDATES PENDING|Opportunity tiles|Reasons by evidence quality|The scorecard and the table|Estate connectivity \(last 15m\)'
    }
}
