BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
}

Describe 'One skin-configured nested SQL lifecycle' {
    It 'leaves the optional guest disabled in both example skins' {
        foreach ($name in 'demo-skin.json', 'dummy-customer.demo-skin.json') {
            Get-DemoNestedSqlGuestConfig -Skin (Get-DemoSkin -Path (Join-Path $repo "config\$name")) |
                Should -BeNullOrEmpty
        }
    }

    It 'rejects malformed enabled configuration before selecting a target' -ForEach @(
        @{ Config = @{ enabled = 'true' } }
        @{ Config = @{ enabled = $true; parentVmName = 'parent'; guestVmName = ''; arcMachineName = 'arc-guest' } }
        @{ Config = @{ enabled = $true; parentVmName = '../parent'; guestVmName = 'guest'; arcMachineName = 'arc-guest' } }
    ) {
        { Get-DemoNestedSqlGuestConfig -Skin @{ nestedSqlGuest = $Config } } | Should -Throw
    }

    InModuleScope Common {
        BeforeAll {
            function Get-VM { param($Name) }
            function Start-VM { param($VM) }
            function Stop-VM { param($VM, [switch]$Confirm, [switch]$AsJob) }
            function Wait-Job { param($Job, $Timeout) }
            function Receive-Job { param($Job) }
            function Remove-Job { param($Job) }
        }
        BeforeEach {
            $script:guest = [pscustomobject]@{ Name = 'sql-guest'; State = 'Off' }
            $script:parent = [pscustomobject]@{ Name = 'parent'; Id = '/fixture/parent'; OsType = 'Windows'; Native = $false }
            Mock Get-VM { $script:guest }
            Mock Start-VM { $script:guest.State = 'Running' }
            Mock Stop-VM { $script:guest.State = 'Off'; [pscustomobject]@{ Id = 123; State = 'Completed' } }
            Mock Wait-Job { param($Job) $Job }
            Mock Receive-Job {}
            Mock Remove-Job {}
            Mock Invoke-DemoGuestCommand {
                param($Machine, $Script)
                & ([scriptblock]::Create($Script))
            }
        }

        It 'starts an Off or Saved guest on an Arc backing parent' -ForEach @(@{ State = 'Off' }, @{ State = 'Saved' }) {
            $script:guest.State = $State
            Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Start |
                Should -Be 'ARC_DEMO_OK'
            Should -Invoke Start-VM -Times 1
        }

        It 'does not restart an already-running guest' {
            $script:guest.State = 'Running'
            Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Start |
                Should -Be 'ARC_DEMO_OK'
            Should -Invoke Start-VM -Times 0
        }

        It 'uses graceful Stop-VM without the invalid Shutdown switch' {
            $script:guest.State = 'Running'
            Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Stop |
                Should -Be 'ARC_DEMO_OK'
            Should -Invoke Stop-VM -Times 1
        }

        It 'does not stop a guest that is already Off' {
            Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Stop |
                Should -Be 'ARC_DEMO_OK'
            Should -Invoke Stop-VM -Times 0
        }

        It 'reports a pending shutdown instead of hard-stopping or cancelling it' {
            $script:guest.State = 'Running'
            Mock Wait-Job { $null }
            { Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Stop } |
                Should -Throw '*still pending*'
            Should -Invoke Remove-Job -Times 0
        }

        It 'rejects an unexpected guest state rather than forcing power off' {
            $script:guest.State = 'Paused'
            { Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Stop } |
                Should -Throw '*unexpected state*'
            Should -Invoke Stop-VM -Times 0
        }

        It 'surfaces missing guest and command failures' {
            Mock Get-VM { throw 'guest missing' }
            { Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Start } |
                Should -Throw '*guest missing*'
        }

        It 'rejects Linux before dispatch' {
            $script:parent.OsType = 'Linux'
            { Invoke-DemoNestedSqlGuest -ParentMachine $script:parent -GuestVmName sql-guest -Action Start } |
                Should -Throw '*Windows parent*'
            Should -Invoke Invoke-DemoGuestCommand -Times 0
        }
    }
}

Describe 'Nested SQL wiring in the normal entry points' {
    BeforeEach {
        $scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra'
        $fixture = @{
            events = [Collections.Generic.List[string]]::new()
            parent = [pscustomobject]@{ Name = 'sql-parent'; Id = "$scope/providers/Microsoft.Compute/virtualMachines/sql-parent"
                OsType = 'Windows'; Native = $true; Monitor = $false; ArcId = $null
                Actual = [pscustomobject]@{ id = "$scope/providers/Microsoft.Compute/virtualMachines/sql-parent"
                    name = 'sql-parent'; powerState = 'VM running'; storageProfile = @{ osDisk = @{ osType = 'Windows' } } } }
            nestedSqlGuest = @{ enabled = $true; parentVmName = 'sql-parent'; guestVmName = 'sql-guest'; arcMachineName = 'arc-guest' }
        }
        $target = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'; NamePrefix = 'fixture' }
        $natId = "$scope/providers/Microsoft.Network/natGateways/natgw-fixture"
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Get-DemoSkin { @{ nestedSqlGuest = $fixture.nestedSqlGuest } }
        Mock Assert-DemoSkinInventory {}
        Mock Get-DemoInventory {
            [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Machines = @($fixture.parent)
                AksClusterIds = @(); ContainerAppIds = @() }
        }
        Mock Get-DemoNetworkState {
            [pscustomobject]@{ NatId = $natId; PublicIp = @{ id = 'pip' }; PublicIpId = 'pip'
                Nat = @{ publicIpAddresses = @(@{ id = 'pip' }) }; SafeToRemove = $false; ConflictMessage = 'fixture retained network' }
        }
        Mock Invoke-DemoNestedSqlGuest {
            param($Action)
            $fixture.events.Add("guest-$Action")
        }
        Mock Wait-DemoNestedSqlArcConnected {}
        Mock Get-DemoReadinessChecks { New-DemoCheck 'vm/power' $fixture.parent.Id 'deallocated' 'deallocated' 'pass' }
        Mock Get-DemoRemovalChecks { New-DemoCheck 'group' '/fixture' 'absent' 'absent' 'pass' }
        Mock Wait-Until {
            param($Condition)
            if (-not (& $Condition)) { throw 'fixture required wait failed' }
            $true
        }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'list') {
                return (@($fixture.parent.Actual) | ConvertTo-Json -Depth 8 -AsArray)
            }
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'show') { return ($fixture.parent.Actual | ConvertTo-Json -Depth 8) }
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'deallocate') {
                $fixture.events.Add('parent-deallocate')
                $fixture.parent.Actual.powerState = 'VM deallocated'
                return ''
            }
            if ($Arguments[0] -eq 'network') { return (@{ id = 'subnet'; natGateway = @{ id = $natId } } | ConvertTo-Json -Depth 5) }
            if ($Arguments[0] -eq 'connectedmachine') { return '[]' }
            if ($Arguments[0] -eq 'group' -and $Arguments[1] -eq 'exists') { return 'false' }
            if ($Arguments[0] -in @('policy', 'consumption')) { return $null }
            throw "Unexpected fixture CLI operation $($Arguments -join ' ')"
        }
    }

    It 'keeps all three lifecycle previews free of guest dispatch' {
        foreach ($name in 'Activate', 'Hibernate', 'Remove') {
            & (Join-Path $repo "scripts\$name-ArcDemo.ps1") @target -WhatIf
        }
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'deallocate' -in $Arguments -or 'delete' -in $Arguments }
    }

    It 'starts the configured guest and waits for its Arc connection' {
        & (Join-Path $repo 'scripts\Activate-ArcDemo.ps1') @target -SkipValidate -SkipPatchAssessment
        $fixture.events | Should -Be @('guest-Start')
        Should -Invoke Wait-DemoNestedSqlArcConnected -Times 1 -ParameterFilter { $ArcMachineName -eq 'arc-guest' }
        Should -Invoke Get-DemoInventory -ParameterFilter { $NestedSqlParentVmName -eq 'sql-parent' }
    }

    It 'shuts down the guest before deallocating its parent' {
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') @target
        $fixture.events | Should -Be @('guest-Stop', 'parent-deallocate')
    }

    It 'still parks compute after a failed guest shutdown without pretending consistency' {
        Mock Invoke-DemoNestedSqlGuest { throw 'guest shutdown timed out' }
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') @target
        $fixture.events | Should -Be @('parent-deallocate')
    }

    It 'does not boot a parked parent during Hibernate or Remove' {
        $fixture.parent.Actual.powerState = 'VM deallocated'
        & (Join-Path $repo 'scripts\Hibernate-ArcDemo.ps1') @target
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -Confirm:$false
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
    }

    It 'gracefully stops a running guest before full removal' {
        & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -Confirm:$false
        $fixture.events | Should -Be @('guest-Stop')
    }

    It 'fails removal before deletion if guest shutdown fails' {
        Mock Invoke-DemoNestedSqlGuest { throw 'shutdown failed' }
        { & (Join-Path $repo 'scripts\Remove-ArcDemo.ps1') @target -Confirm:$false } | Should -Throw '*shutdown failed*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { 'delete' -in $Arguments }
    }

    It 'checks nested Arc readiness without a guest command' -ForEach @(
        @{ Observed = 'Connected'; Expected = 'pass'; ExitCode = 0 }
        @{ Observed = 'Disconnected'; Expected = 'pending'; ExitCode = 2 }
    ) {
        Mock Invoke-DemoAz {
            (@{ id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines/arc-guest'
                status = $Observed } | ConvertTo-Json)
        } -ParameterFilter { $Arguments[0] -eq 'connectedmachine' }
        $result = & (Join-Path $repo 'scripts\Test-ArcDemoReadiness.ps1') @target -OutputFormat Json | ConvertFrom-Json
        $LASTEXITCODE | Should -Be $ExitCode
        ($result.checks | Where-Object id -eq 'nested/arc').status | Should -Be $Expected
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
    }
}
