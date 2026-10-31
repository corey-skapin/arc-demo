BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\Common.psm1')
    $script:buildScript = Join-Path $PSScriptRoot '..\scripts\New-NestedSqlDemo.ps1'
}
Describe 'Scratch build and lifecycle skin agree before dispatch' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Invoke-AzRest { throw 'Unexpected live transport' }
        $fixture = @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'parent'
            guestVmName = 'DemoNew'; arcMachineName = 'DemoNew' } }
        Mock Get-DemoSkin { $fixture }
        $script:buildArguments = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            TenantId = '22222222-2222-2222-2222-222222222222'
            ParentVmId = '33333333-3333-3333-3333-333333333333'
            ParentResourceGroup = 'rg-fixture-infra'; ParentVmName = 'parent'
            ResourceGroup = 'rg-fixture'; Location = 'australiaeast'
            VmName = 'DemoNew'; VmRoot = 'D:\NestedSQL\VMs\DemoNew'; SwitchName = 'FixtureSwitch'
            WindowsIsoPath = 'D:\Media\Windows.iso'; SqlIsoPath = 'D:\Media\Sql.iso'
            GuestCredential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'Synthetic!Credential123456789' -AsPlainText -Force))
            GuestAddress = '192.0.2.10'; Gateway = '192.0.2.1'; DnsServer = '192.0.2.1'
            OnboardingApplicationId = '44444444-4444-4444-4444-444444444444'
            SecretVersionUri = 'https://fixture.vault.azure.net/secrets/arc-onboarding-client-secret/synthetic'
            VaultPrivateAddress = '192.0.2.2'; SkinPath = 'private-fixture.json'
        }
    }
    It 'previews the matched build without dispatching any parent or Azure operation' {
        & $script:buildScript @script:buildArguments -WhatIf
        Should -Invoke Invoke-AzRest -Times 0
    }
    It 'rejects disabled or mismatched skin names before account or transport calls' -ForEach @(
        @{ Wrong = 'disabled' }, @{ Wrong = 'parent' }, @{ Wrong = 'guest' }, @{ Wrong = 'arc' }
    ) {
        switch ($Wrong) {
            disabled { $fixture.nestedSqlGuest.enabled = $false }
            parent { $fixture.nestedSqlGuest.parentVmName = 'other-parent' }
            guest { $fixture.nestedSqlGuest.guestVmName = 'other-guest' }
            arc { $fixture.nestedSqlGuest.arcMachineName = 'other-arc' }
        }
        { & $script:buildScript @script:buildArguments -Confirm:$false } | Should -Throw '*match*'
        Should -Invoke Initialize-DemoContext -Times 0
        Should -Invoke Invoke-AzRest -Times 0
    }
}
