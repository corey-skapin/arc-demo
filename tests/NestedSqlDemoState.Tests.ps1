BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\Common.psm1')
    $script:stateScript = Join-Path $PSScriptRoot '..\scripts\Set-NestedSqlDemoState.ps1'
}
Describe 'Skin-configured scoped nested demo lifecycle' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Get-DemoSkin { @{ azure = @{ namePrefix = 'fixture' }; nestedSqlGuest = @{
            enabled = $true; parentVmName = 'parent'; guestVmName = 'DemoNew'; arcMachineName = 'arc-guest' } } }
        $fixture = @{ parent = @{
            id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines/parent'
            vmId = '33333333-3333-3333-3333-333333333333'
            powerState = 'VM running'; storageProfile = @{ osDisk = @{ osType = 'Windows' } }
        }; events = [Collections.Generic.List[string]]::new() }
        Mock Invoke-DemoAz {
            if ($Arguments[1] -eq 'show') { return ($fixture.parent | ConvertTo-Json -Depth 6) }
            if ($Arguments[1] -eq 'deallocate') { $fixture.events.Add('park-parent'); $fixture.parent.powerState = 'VM deallocated'; return }
            if ($Arguments[1] -eq 'start') { $fixture.events.Add('wake-parent'); $fixture.parent.powerState = 'VM running'; return }
            throw 'Unexpected CLI operation'
        }
        Mock Invoke-DemoNestedSqlGuest { $fixture.events.Add("guest-$Action") }
        Mock Wait-DemoNestedSqlArcConnected {}
        Mock Wait-Until { if (-not (& $Condition)) { throw 'required state not observed' }; $true }
        $script:target = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            TenantId = '22222222-2222-2222-2222-222222222222'
            SkinPath = 'private-fixture.json'; State = 'Stopped'
        }
    }
    It 'previews without stopping the guest or deallocating the parent' {
        & $script:stateScript @script:target -WhatIf
        Should -Invoke Invoke-DemoAz -Times 1
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
    }
    It 'rejects wrong parent identity or OS before mutation' -ForEach @(
        @{ Wrong = 'id' }, @{ Wrong = 'os' }
    ) {
        if ($Wrong -eq 'id') { $fixture.parent.id += '-wrong' } else { $fixture.parent.storageProfile.osDisk.osType = 'Linux' }
        { & $script:stateScript @script:target -Confirm:$false } | Should -Throw '*unexpected*'
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
    }
    It 'gracefully stops the configured guest before parking only its parent' {
        & $script:stateScript @script:target -Confirm:$false | Out-Null
        $fixture.events | Should -Be @('guest-Stop', 'park-parent')
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 1 -ParameterFilter { $GuestVmName -eq 'DemoNew' }
    }
    It 'does not park the scoped parent after a failed graceful shutdown' {
        Mock Invoke-DemoNestedSqlGuest { throw 'guest shutdown failed' }
        { & $script:stateScript @script:target -Confirm:$false } | Should -Throw '*shutdown failed*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -eq 'deallocate' }
    }
    It 'wakes the same parent before starting the guest and checking Arc' {
        $fixture.parent.powerState = 'VM deallocated'
        $script:target.State = 'Running'
        & $script:stateScript @script:target -Confirm:$false | Out-Null
        $fixture.events | Should -Be @('wake-parent', 'guest-Start')
        Should -Invoke Wait-DemoNestedSqlArcConnected -Times 1 -ParameterFilter { $ArcMachineName -eq 'arc-guest' }
    }
    It 'keeps an already-parked pair parked without guest dispatch' {
        $fixture.parent.powerState = 'VM deallocated'
        & $script:stateScript @script:target -Confirm:$false | Out-Null
        Should -Invoke Invoke-DemoNestedSqlGuest -Times 0
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[1] -ne 'show' }
    }
}
