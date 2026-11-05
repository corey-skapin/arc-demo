BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:deployScript = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
    $script:ast = [Management.Automation.Language.Parser]::ParseFile($script:deployScript, [ref]$null, [ref]$null)
}

Describe 'Deploy warns before it submits when a VM is already not Succeeded' {
    BeforeAll {
        $loop = $script:ast.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'busyVm' }, $true)
        $script:busyLoop = $loop.Extent.Text
    }
    It 'names each busy VM, says why the wait is long and what not to do, and ignores healthy and unknown ones' {
        $global:WarnLog = [System.Collections.Generic.List[string]]::new()
        function Write-Warn { param([string]$Message) $global:WarnLog.Add($Message) }
        try {
            $existingVms = @(
                [pscustomobject]@{ name = 'lnx-app-01'; provisioningState = 'Updating' }
                [pscustomobject]@{ name = 'lnx-app-02'; provisioningState = 'Succeeded' }
                [pscustomobject]@{ name = 'win-app-01' }
                [pscustomobject]@{ name = 'win-app-02'; provisioningState = 'Failed' })
            & ([scriptblock]::Create($script:busyLoop))
            $global:WarnLog.Count | Should -Be 2
            $global:WarnLog[0] | Should -Match '^VM lnx-app-01 is Updating\. .*about 90 minutes.*Defender MDE\.Linux install lock'
            $global:WarnLog[0] | Should -Match 'Do not cancel it, reapply the VM or send it a Run Command'
            $global:WarnLog[0] | Should -Match 'docs/troubleshooting\.md, A Linux VM stays Updating behind a Defender MDE\.Linux install lock'
            $global:WarnLog[1] | Should -Match '^VM win-app-02 is Failed\.'
        } finally {
            Remove-Item Function:\Write-Warn -ErrorAction SilentlyContinue
            Remove-Variable WarnLog -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Deploy says which VM auto-shutdown schedules it is about to change' {
    BeforeAll {
        $block = $script:ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$existingVms.Count' }, $true)
        $script:scheduleBlock = $block.Extent.Text
    }
    BeforeEach {
        $global:WarnLog = [System.Collections.Generic.List[string]]::new()
        function Write-Warn { param([string]$Message) $global:WarnLog.Add($Message) }
        $script:schedules = @()
        $script:rest = $null
        Mock Invoke-AzRest {
            $script:rest = "$Method $Url"
            if ($script:schedules -eq 'denied') { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            [pscustomobject]@{ value = @($script:schedules) }
        }
        $SubscriptionId = '11111111-1111-1111-1111-111111111111'
        $infraRg = 'rg-fixture-infra'
        $AutoShutdownTime = '2300'
        $AutoShutdownTimezone = 'Cen. Australia Standard Time'
        $existingVms = @([pscustomobject]@{ name = 'lnx-app-01' })
        function New-Schedule { param($Name, $Time = '2300', $Zone = 'Cen. Australia Standard Time') [pscustomobject]@{ name = $Name; properties = [pscustomobject]@{ dailyRecurrence = [pscustomobject]@{ time = $Time }; timeZoneId = $Zone } } }
    }
    AfterEach {
        Remove-Item Function:\Write-Warn -ErrorAction SilentlyContinue
        Remove-Item Function:\New-Schedule -ErrorAction SilentlyContinue
        Remove-Variable WarnLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'reads the schedules of the infra group through ARM and says nothing when they already match' {
        $script:schedules = @((New-Schedule 'shutdown-computevm-lnx-app-01'), (New-Schedule 'shutdown-computevm-win-app-01'))
        & ([scriptblock]::Create($script:scheduleBlock))
        $script:rest | Should -Be 'Get https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.DevTestLab/schedules?api-version=2018-09-15'
        $global:WarnLog.Count | Should -Be 0
    }
    It 'warns about a hand-changed schedule, naming the VM, its time and how to keep another time' {
        $script:schedules = @((New-Schedule 'shutdown-computevm-lnx-app-01' '1900'), (New-Schedule 'shutdown-computevm-win-app-01'))
        & ([scriptblock]::Create($script:scheduleBlock))
        $global:WarnLog.Count | Should -Be 1
        $global:WarnLog[0] | Should -Match '^1 VM auto-shutdown schedule\(s\) differ from the requested 2300 \(Cen\. Australia Standard Time\) and this Deploy sets them to it: shutdown-computevm-lnx-app-01 1900\.'
        $global:WarnLog[0] | Should -Match 'operations\.autoShutdownTime in the skin \(or autoShutdownTime in the build config\)'
        $global:WarnLog[0] | Should -Match 'reverted'
    }
    It 'treats a different time zone as a change and shortens a long list' {
        $script:schedules = @(1..6 | ForEach-Object { New-Schedule "shutdown-computevm-vm$_" '2300' 'UTC' })
        & ([scriptblock]::Create($script:scheduleBlock))
        $global:WarnLog[0] | Should -Match '^6 VM auto-shutdown schedule\(s\) differ'
        $global:WarnLog[0] | Should -Match 'shutdown-computevm-vm4 2300, \.\.\.\.'
        $global:WarnLog[0] | Should -Not -Match 'vm5'
    }
    It 'says plainly that it could not read them, and carries on, when ARM refuses' {
        $script:schedules = 'denied'
        { & ([scriptblock]::Create($script:scheduleBlock)) } | Should -Not -Throw
        $global:WarnLog.Count | Should -Be 1
        $global:WarnLog[0] | Should -Match '^Could not read the existing VM auto-shutdown schedules \(.*403.*\); this Deploy sets them to 2300 \(Cen\. Australia Standard Time\)\.$'
    }
    It 'makes no call on a first deployment, when no VM exists yet' {
        $existingVms = @()
        & ([scriptblock]::Create($script:scheduleBlock))
        $script:rest | Should -BeNullOrEmpty
        $global:WarnLog.Count | Should -Be 0
    }
}
