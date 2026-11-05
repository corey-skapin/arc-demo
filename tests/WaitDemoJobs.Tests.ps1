BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
}

Describe 'Wait-DemoJobs' {
    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { $script:lines.Add([string]$Message) } -ModuleName Common
        $script:started = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach {
        foreach ($job in $script:started) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }

    It 'returns as soon as every job has finished and leaves the jobs for the receiver' {
        $a = Start-Job -Name 'vm-fixture-a' -ScriptBlock { 'a' }
        $b = Start-Job -Name 'vm-fixture-b' -ScriptBlock { 'b' }
        $script:started.Add($a); $script:started.Add($b)
        Wait-DemoJobs -Jobs @($a, $b) -TimeoutSeconds 60
        $a.State | Should -Be 'Completed'
        $b.State | Should -Be 'Completed'
        (Get-Job -Id $a.Id).Name | Should -Be 'vm-fixture-a'
    }

    It 'names every job that is still pending in the progress line, and only those' {
        $quick = Start-Job -Name 'vm-fixture-quick' -ScriptBlock { 'done' }
        $slow = Start-Job -Name 'vm-fixture-slow' -ScriptBlock { Start-Sleep -Seconds 4; 'done' }
        $slower = Start-Job -Name 'vm-fixture-slower' -ScriptBlock { Start-Sleep -Seconds 4; 'done' }
        $script:started.Add($quick); $script:started.Add($slow); $script:started.Add($slower)
        $quick | Wait-Job | Out-Null
        Wait-DemoJobs -Jobs @($quick, $slow, $slower) -TimeoutSeconds 60
        $script:lines.Count | Should -BeGreaterThan 0
        $script:lines[0] | Should -Match '^Waiting for guest/extension jobs: vm-fixture-slow(er)?, vm-fixture-slow(er)? \(\d+ s remaining\)$'
        $script:lines[0] | Should -Not -Match 'quick'
        $slow.State | Should -Be 'Completed'
    }

    It 'stops waiting at the deadline without throwing and without touching a job that is still running' {
        $stuck = Start-Job -Name 'vm-fixture-stuck' -ScriptBlock { Start-Sleep -Seconds 120 }
        $script:started.Add($stuck)
        $began = Get-Date
        { Wait-DemoJobs -Jobs @($stuck) -TimeoutSeconds 3 } | Should -Not -Throw
        ((Get-Date) - $began).TotalSeconds | Should -BeLessThan 20
        $stuck.State | Should -Be 'Running'
        $script:lines[-1] | Should -Match 'vm-fixture-stuck'
    }
}
