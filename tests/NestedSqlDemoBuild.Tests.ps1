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
            SkinPath = 'private-fixture.json'
        }
    }

    Describe 'One-build onboarding credential lifecycle' {
        BeforeAll {
            $ast = [Management.Automation.Language.Parser]::ParseFile($script:buildScript,[ref]$null,[ref]$null)
            foreach ($name in @('Invoke-NestedSqlGraphRequest','Get-NestedSqlApplication','Get-NestedSqlCredentialKeyIdSet',
                'Test-NestedSqlCredentialSet','Invoke-NestedSqlCredentialBuild')) {
                $functionAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name },$true)
                . ([scriptblock]::Create($functionAst.Extent.Text))
            }
        }
        BeforeEach {
            $script:credentialEvents = [Collections.Generic.List[string]]::new()
            $script:graphGetCount = 0
            $script:baselineKeyId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $script:mintedKeyId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $script:applicationId = [guid]'44444444-4444-4444-4444-444444444444'
            Mock Start-Sleep {}
            Mock Invoke-DemoAz {
                $urlAt = [array]::IndexOf($Arguments,'--url')
                $url = $Arguments[$urlAt + 1]
                if ($url -like '*/addPassword') {
                    $script:credentialEvents.Add('mint')
                    return (@{secretText='synthetic-one-build-secret';keyId=$script:mintedKeyId} | ConvertTo-Json -Compress)
                }
                if ($url -like '*/removePassword') {
                    $bodyAt = [array]::IndexOf($Arguments,'--body')
                    $requestPath = $Arguments[$bodyAt + 1].Substring(1)
                    $removeBody = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
                    if ($removeBody.keyId -ne $script:mintedKeyId -or $removeBody.passwordCredential) {
                        throw 'removePassword must receive the exact top-level keyId.'
                    }
                    $script:credentialEvents.Add('cleanup')
                    return ''
                }
                if ($url -like '*/applications%28*') {
                    $script:graphGetCount++
                    $ids = if ($script:graphGetCount -eq 1 -or $script:graphGetCount -ge 3) {
                        @($script:baselineKeyId)
                    } else {
                        @($script:baselineKeyId,$script:mintedKeyId)
                    }
                    $credentials = @($ids | ForEach-Object { @{keyId=$_} })
                    return (@{appId="$($script:applicationId)";passwordCredentials=$credentials} | ConvertTo-Json -Depth 5 -Compress)
                }
                throw "Unexpected Graph URL: $url"
            }
        }
        It 'mints, delivers only the secure value to the action, removes it, and preserves original keys' {
            $action = {
                param([securestring]$Secret)
                $script:credentialEvents.Add('deliver')
                [pscredential]::new('synthetic',$Secret).GetNetworkCredential().Password | Should -Be 'synthetic-one-build-secret'
                'completed'
            }
            $result = Invoke-NestedSqlCredentialBuild -ApplicationId $script:applicationId `
                -DisplayName 'nested-demo-fixture' -Action $action
            $result | Should -Be 'completed'
            ($script:credentialEvents -join ',') | Should -Be 'mint,deliver,cleanup'
            $script:graphGetCount | Should -Be 3
        }
        It 'removes the minted credential when the build action fails' {
            $action = { param([securestring]$Secret) $script:credentialEvents.Add('deliver'); throw 'synthetic build failure' }
            { Invoke-NestedSqlCredentialBuild -ApplicationId $script:applicationId `
                -DisplayName 'nested-demo-failure' -Action $action } | Should -Throw '*synthetic build failure*'
            ($script:credentialEvents -join ',') | Should -Be 'mint,deliver,cleanup'
            $script:graphGetCount | Should -Be 3
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
