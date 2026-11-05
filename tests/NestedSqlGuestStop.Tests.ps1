BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:parent = [pscustomobject]@{ Name = 'sql-parent'; Id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines/sql-parent'; OsType = 'Windows' }
}

Describe 'Invoke-DemoNestedSqlGuest guest script' {
    BeforeEach {
        $global:CapturedGuestScript = $null
        Mock Invoke-DemoGuestCommand { $global:CapturedGuestScript = $Script } -ModuleName Common
    }
    AfterEach { Remove-Variable CapturedGuestScript -Scope Global -ErrorAction SilentlyContinue }

    It 'is valid PowerShell for every action and tolerance, with the placeholders replaced' {
        foreach ($case in @(@{ Action = 'Start'; Absent = $false }, @{ Action = 'Stop'; Absent = $false }, @{ Action = 'Stop'; Absent = $true })) {
            $arguments = @{ ParentMachine = $script:parent; GuestVmName = 'sql-guest'; Action = $case.Action }
            if ($case.Absent) { $arguments.AllowAbsent = $true }
            Invoke-DemoNestedSqlGuest @arguments
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($global:CapturedGuestScript, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $global:CapturedGuestScript | Should -Not -Match '__[A-Z_]+__'
            $global:CapturedGuestScript | Should -Match "\`$guestName = 'sql-guest'"
            $global:CapturedGuestScript | Should -Match "\`$action = '$($case.Action)'"
            $global:CapturedGuestScript | Should -Match "\`$allowAbsent = '$($case.Absent.ToString().ToLowerInvariant())' -eq 'true'"
        }
    }

    It 'with -AllowAbsent treats a missing Hyper-V role or guest as already stopped, and otherwise still requires exactly one guest' {
        Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName 'sql-guest' -Action Stop -AllowAbsent
        $text = $global:CapturedGuestScript
        $text | Should -Match "if \(\`$allowAbsent -and -not \(Get-Command Get-VM -ErrorAction SilentlyContinue\)\)"
        $text | Should -Match 'there is no guest to stop\.'
        $text | Should -Match 'so there is nothing to stop\.'
        $text | Should -Match '(?s)if \(\$guest\.Count -ne 1\) \{ throw "Expected exactly one Hyper-V guest named'
    }

    It 'refuses -AllowAbsent for Start: a guest that must start has to exist' {
        { Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName 'sql-guest' -Action Start -AllowAbsent } | Should -Throw '*only applies to Stop*'
        Should -Invoke Invoke-DemoGuestCommand -ModuleName Common -Times 0
    }
}
