BeforeDiscovery {
    $Expected = @(
        @{
            File  = 'workbooks/arc-compliance.workbook.json'
            Names = @(
                'Posture at a glance', 'Policy and secure score', 'Policy compliance', 'Patching and Defender agent', 'Fully patched',
                'Patch posture', 'Patch status', 'Security pending', 'Assessment gaps',
                'Arc servers with pending critical or security updates', 'Assessment failed', 'Not assessed'
            )
        }
        @{
            File  = 'workbooks/nseilaz/ArcMachineIntelligenceCenter.json'
            Names = @('Machine at a glance', 'Arc identity', 'Newest telemetry', 'Performance', 'Security', 'SQL Server', 'Arc and policy', 'Events and uptime')
        }
        @{
            File  = 'workbooks/arc-governance.workbook.json'
            Names = @('Vulnerability findings')
        }
    )
}

BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    # The template wraps lines, so compare on whitespace-collapsed text.
    $script:Template = (Get-Content -LiteralPath (Join-Path $script:Repo 'docs/runsheet.md') -Raw) -replace '\s+', ' '
}

Describe 'Presenter template names that belong to a rebuilt workbook exist in that workbook' {
    It '<File>: every name the template shows in bold is a tile, section, tab or label there' -ForEach $Expected {
        $workbook = (Get-Content -LiteralPath (Join-Path $script:Repo $File) -Raw) -replace '\\n', ' '
        foreach ($name in $Names) {
            $script:Template | Should -Match ([regex]::Escape("**$name**")) -Because "the template should name $name in bold"
            $workbook | Should -Match ([regex]::Escape($name)) -Because "$File must contain '$name'"
        }
    }

    It 'no longer describes the old tiles, the heuristic scorecard or the empty-by-design governance workbook' {
        $script:Template | Should -Not -Match 'empty by design'
        $script:Template | Should -Not -Match 'The scorecard and the table'
        $script:Template | Should -Not -Match 'table only the Windows hosts have'
        $script:Template | Should -Not -Match 'vulnerability tiles'
    }
}
