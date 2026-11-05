BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
    $script:deployScript = Join-Path $repo 'scripts\Deploy-ArcDemo.ps1'
    InModuleScope Common {
        $script:contextBeforeOnboardingTests = @{ Subscription = $script:DemoSubscription; Tenant = $script:DemoTenant }
    }

    # One shared fixture holds the fake directory, Graph and role state for the module-bound az stand-in and for the tests.
    function New-OnboardingFixture {
        $global:OnboardingFixture = @{
            spName = 'sp-fixture-onboard'
            sps = @(@{ id = '55555555-5555-5555-5555-555555555555'; appId = '44444444-4444-4444-4444-444444444444' })
            rgExists = $true
            assignments = @()
            baselineKey = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            mintedKey = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            createdKey = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            keys = @('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
            keyNames = @{}
            apps = @()
            mintedSecret = 'Synthetic-Onboarding-Secret-7419'
            createdSecret = 'Synthetic-Created-Secret-3306'
            mintDenied = $false; removeFails = $false; removeDeletesBaseline = $false; failGuestOn = ''
            events = [Collections.Generic.List[string]]::new()
            messages = [Collections.Generic.List[string]]::new()
            sleeps = [Collections.Generic.List[int]]::new()
            guestScripts = [Collections.Generic.List[object]]::new()
            graphGets = 0; roleCreate = $null; created = $null; delivered = $null
        }
    }

    $script:fakeAz = {
        param($Arguments)
        $fx = $global:OnboardingFixture
        $verb = "$($Arguments[0]) $($Arguments[1])"
        if ($verb -eq 'group exists') {
            $fx.events.Add('group-exists')
            return (ConvertTo-Json -InputObject ([bool]$fx.rgExists))
        }
        if ($verb -eq 'ad sp') {
            if ($Arguments[2] -eq 'list') {
                $fx.events.Add('sp-list')
                $name = $Arguments[[array]::IndexOf($Arguments, '--display-name') + 1]
                $rows = if ($name -eq $fx.spName) { @($fx.sps) } else { @() }
                return (ConvertTo-Json -InputObject @($rows) -Depth 3)
            }
            if ($Arguments[2] -eq 'show') {
                $fx.events.Add('sp-show')
                $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
                if ($id -ne $fx.sps[0].appId) { throw 'Azure CLI ad sp failed (exit 1): the service principal does not exist.' }
                return (ConvertTo-Json -InputObject $fx.sps[0] -Depth 3)
            }
            if ($Arguments[2] -eq 'create-for-rbac') {
                $fx.events.Add('sp-create')
                $fx.created = $Arguments
                $fx.sps = @(@{ id = '55555555-5555-5555-5555-555555555555'; appId = '44444444-4444-4444-4444-444444444444' })
                $fx.keys += $fx.createdKey
                $fx.keyNames[$fx.createdKey] = 'rbac'
                return (@{ appId = $fx.sps[0].appId; displayName = $fx.spName; password = $fx.createdSecret; tenant = '22222222-2222-2222-2222-222222222222' } | ConvertTo-Json -Compress)
            }
        }
        if ($verb -eq 'ad app') {
            if ($Arguments[2] -eq 'list') {
                $fx.events.Add('app-list')
                return (ConvertTo-Json -InputObject @($fx.apps) -Depth 4)
            }
        }
        if ($verb -eq 'role assignment') {
            if ($Arguments[2] -eq 'list') {
                $fx.events.Add('role-list')
                if ($Arguments[[array]::IndexOf($Arguments, '--assignee-object-id') + 1] -ne $fx.sps[0].id) { return '[]' }
                return (ConvertTo-Json -InputObject @($fx.assignments) -Depth 4)
            }
            if ($Arguments[2] -eq 'create') {
                $fx.events.Add('role-create')
                $fx.roleCreate = $Arguments
                $fx.assignments += @{ scope = $Arguments[[array]::IndexOf($Arguments, '--scope') + 1]; roleDefinitionName = 'Azure Connected Machine Onboarding' }
                return $null
            }
        }
        if ($Arguments[0] -eq 'rest') {
            $url = $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            if ($url -like '*/addPassword') {
                if ($fx.mintDenied) { throw 'Azure CLI rest POST failed (exit 1): Forbidden({"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}})' }
                $fx.events.Add('mint')
                $fx.keys += $fx.mintedKey
                return (@{ secretText = $fx.mintedSecret; keyId = $fx.mintedKey } | ConvertTo-Json -Compress)
            }
            if ($url -like '*/removePassword') {
                $body = Get-Content -LiteralPath $Arguments[[array]::IndexOf($Arguments, '--body') + 1].Substring(1) -Raw | ConvertFrom-Json
                if ($body.keyId -notin @($fx.mintedKey, $fx.createdKey) -or $body.passwordCredential) { throw 'removePassword must receive the exact top-level keyId.' }
                if ($fx.removeFails) { throw 'Azure CLI rest POST failed (exit 1): (ServiceUnavailable) The service is temporarily unavailable.' }
                $fx.events.Add($(if ($body.keyId -eq $fx.createdKey) { 'creation-cleanup' } else { 'cleanup' }))
                $removed = $body.keyId
                $fx.keys = @($fx.keys | Where-Object { $_ -ne $removed -and -not ($fx.removeDeletesBaseline -and $_ -eq $fx.baselineKey) })
                return ''
            }
            if ($url -like '*/applications%28*') {
                $fx.graphGets++
                $fx.events.Add('graph-get')
                return (@{ appId = $fx.sps[0].appId; passwordCredentials = @($fx.keys | ForEach-Object { @{ keyId = $_; displayName = $(if ($fx.keyNames.ContainsKey($_)) { $fx.keyNames[$_] } else { 'baseline' }) } }) } | ConvertTo-Json -Depth 5 -Compress)
            }
            throw "Unexpected Graph URL: $url"
        }
        throw "Unexpected Azure CLI call: $($Arguments[0..1] -join ' ')"
    }
}
AfterAll {
    Remove-Variable -Name OnboardingFixture -Scope Global -ErrorAction SilentlyContinue
    InModuleScope Common {
        $script:DemoSubscription = $script:contextBeforeOnboardingTests.Subscription
        $script:DemoTenant = $script:contextBeforeOnboardingTests.Tenant
    }
}

Describe 'Initialize-DemoOnboardingIdentity' {
    BeforeEach {
        New-OnboardingFixture
        InModuleScope Common {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $script:DemoTenant = '22222222-2222-2222-2222-222222222222'
        }
        Mock Invoke-DemoAz -ModuleName Common -MockWith $script:fakeAz
        Mock Start-Sleep -ModuleName Common { $global:OnboardingFixture.sleeps.Add([int]$Seconds) }
        Mock Write-Ok -ModuleName Common { $global:OnboardingFixture.messages.Add([string]$Message) }
        Mock Write-Step -ModuleName Common { $global:OnboardingFixture.messages.Add([string]$Message) }
        Mock Write-Warn -ModuleName Common { $global:OnboardingFixture.messages.Add([string]$Message) }
        $script:deliver = {
            param([string]$ApplicationId, [securestring]$Secret)
            $global:OnboardingFixture.events.Add('deliver')
            $global:OnboardingFixture.delivered = @{
                ApplicationId = $ApplicationId; Type = $Secret.GetType().Name
                Text = [pscredential]::new('fixture', $Secret).GetNetworkCredential().Password
            }
            'completed'
        }
    }

    Context 'the service principal already exists' {
        It 'grants the role at the Arc group, mints a one-day credential, delivers it, removes it and keeps the original keys' {
            $fx = $global:OnboardingFixture
            $result = Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver
            $result | Should -Be 'completed'
            $steps = @($fx.events | Where-Object { $_ -in 'group-exists', 'role-create', 'mint', 'deliver', 'cleanup', 'sp-create' })
            $steps -join ',' | Should -Be 'group-exists,role-create,mint,deliver,cleanup'
            $fx.graphGets | Should -Be 3
            $fx.keys | Should -Be @($fx.baselineKey)
            $fx.delivered.ApplicationId | Should -Be '44444444-4444-4444-4444-444444444444'
            $fx.delivered.Type | Should -Be 'SecureString'
            $fx.delivered.Text | Should -Be $fx.mintedSecret
            $roleArguments = $fx.roleCreate -join ' '
            $roleArguments | Should -Match '--assignee-object-id 55555555-5555-5555-5555-555555555555 '
            $roleArguments | Should -Match '--assignee-principal-type ServicePrincipal '
            $roleArguments | Should -Match "--role Azure Connected Machine Onboarding "
            $roleArguments | Should -Match '--scope /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture '
            $fx.sleeps | Should -Be @(90)
        }
        It 'does not create a role that the Arc group already has and does not wait' {
            $fx = $global:OnboardingFixture
            $fx.assignments = @(@{ scope = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/RG-FIXTURE'; roleDefinitionName = 'Azure Connected Machine Onboarding' })
            Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver | Out-Null
            $fx.events | Should -Not -Contain 'role-create'
            $fx.sleeps.Count | Should -Be 0
            $fx.events | Should -Contain 'cleanup'
        }
        It 'does not count a role assigned at a parent scope' {
            $fx = $global:OnboardingFixture
            $fx.assignments = @(@{ scope = '/subscriptions/11111111-1111-1111-1111-111111111111'; roleDefinitionName = 'Azure Connected Machine Onboarding' })
            Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver | Out-Null
            $fx.events | Should -Contain 'role-create'
        }
        It 'removes the credential and keeps the original keys when onboarding fails' {
            $fx = $global:OnboardingFixture
            $failing = { param([string]$ApplicationId, [securestring]$Secret) $global:OnboardingFixture.events.Add('deliver'); throw 'synthetic onboarding failure' }
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $failing } | Should -Throw '*synthetic onboarding failure*'
            ($fx.events | Where-Object { $_ -in 'mint', 'deliver', 'cleanup' }) -join ',' | Should -Be 'mint,deliver,cleanup'
            $fx.graphGets | Should -Be 3
            $fx.keys | Should -Be @($fx.baselineKey)
        }
        It 'reports a credential it could not remove together with its expiry and the onboarding failure' {
            $fx = $global:OnboardingFixture
            $fx.removeFails = $true
            $failing = { param([string]$ApplicationId, [securestring]$Secret) throw 'synthetic onboarding failure' }
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $failing } |
                Should -Throw '*cleanup/verification failed; it expires at*ServiceUnavailable*Failure: synthetic onboarding failure*'
        }
        It 'fails loudly when removal changes the original credentials' {
            $fx = $global:OnboardingFixture
            $fx.removeDeletesBaseline = $true
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } |
                Should -Throw '*cleanup/verification failed*changed beyond the minted credential*'
        }
        It 'gives -OnboardingSecret guidance and runs nothing when the operator cannot add a credential' {
            $fx = $global:OnboardingFixture
            $fx.mintDenied = $true
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } |
                Should -Throw '*Could not add a one-day credential*Insufficient privileges*-OnboardingSecret*'
            $fx.events | Should -Not -Contain 'deliver'
            $fx.events | Should -Not -Contain 'cleanup'
            $fx.keys | Should -Be @($fx.baselineKey)
        }
        It 'passes a supplied secret through without touching any credential' {
            $fx = $global:OnboardingFixture
            $supplied = ConvertTo-SecureString 'Synthetic-Supplied-Secret-5521' -AsPlainText -Force
            Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -ExistingSecret $supplied -Action $script:deliver | Out-Null
            $fx.delivered.Text | Should -Be 'Synthetic-Supplied-Secret-5521'
            $fx.events | Should -Not -Contain 'graph-get'
            $fx.events | Should -Not -Contain 'mint'
            $fx.events | Should -Contain 'role-create'
        }
        It 'looks the application up by ID for the nested build' {
            $fx = $global:OnboardingFixture
            Initialize-DemoOnboardingIdentity -ApplicationId '44444444-4444-4444-4444-444444444444' -ResourceGroup rg-fixture `
                -DisplayName 'nested-fixture' -Action $script:deliver | Out-Null
            $fx.events | Should -Contain 'sp-show'
            $fx.events | Should -Not -Contain 'sp-list'
            ($fx.events | Where-Object { $_ -in 'mint', 'deliver', 'cleanup' }) -join ',' | Should -Be 'mint,deliver,cleanup'
        }
        It 'never prints or logs the secret' {
            $fx = $global:OnboardingFixture
            $output = Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver *>&1 | Out-String
            ($output + ($fx.messages -join "`n")) | Should -Not -Match 'Synthetic-Onboarding-Secret'
        }
    }

    Context 'there is no service principal yet' {
        BeforeEach { $global:OnboardingFixture.sps = @(); $global:OnboardingFixture.keys = @() }
        It 'creates it with the role at the Arc group, waits, delivers its secret, stores nothing and removes the one-year credential the creation added' {
            $fx = $global:OnboardingFixture
            $output = Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver *>&1 | Out-String
            $created = $fx.created -join ' '
            $created | Should -Match '--name sp-fixture-onboard '
            $created | Should -Match '--role Azure Connected Machine Onboarding '
            $created | Should -Match '--scopes /subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture '
            $fx.events | Should -Not -Contain 'mint'
            $fx.events | Should -Not -Contain 'role-create'
            $fx.delivered.Type | Should -Be 'SecureString'
            $fx.delivered.Text | Should -Be $fx.createdSecret
            $fx.delivered.ApplicationId | Should -Be '44444444-4444-4444-4444-444444444444'
            $fx.sleeps | Should -Be @(90)
            ($fx.events | Where-Object { $_ -in 'app-list', 'sp-create', 'deliver', 'creation-cleanup' }) -join ',' | Should -Be 'app-list,sp-create,deliver,creation-cleanup'
            $fx.keys.Count | Should -Be 0
            ($output + ($fx.messages -join "`n")) | Should -Not -Match 'Synthetic-Created-Secret'
        }
        It 'keeps the credentials an existing application of that name already had and removes only the one it added' {
            $fx = $global:OnboardingFixture
            $fx.keys = @($fx.baselineKey)
            $fx.apps = @(@{ appId = '44444444-4444-4444-4444-444444444444'; keys = @($fx.baselineKey) })
            Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver | Out-Null
            $fx.keys | Should -Be @($fx.baselineKey)
            $fx.events | Should -Contain 'creation-cleanup'
        }
        It 'removes the credential the creation added, and rethrows the failure, when onboarding fails' {
            $fx = $global:OnboardingFixture
            $failing = { param([string]$ApplicationId, [securestring]$Secret) $global:OnboardingFixture.events.Add('deliver'); throw 'synthetic onboarding failure' }
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $failing } | Should -Throw '*synthetic onboarding failure*'
            $fx.events | Should -Contain 'creation-cleanup'
            $fx.keys.Count | Should -Be 0
        }
        It 'names the manual command, with the key, when the creation credential cannot be removed' {
            $fx = $global:OnboardingFixture
            $fx.removeFails = $true
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } |
                Should -Throw "*could not be removed*ServiceUnavailable*az ad app credential delete --id 44444444-4444-4444-4444-444444444444 --key-id $($fx.createdKey)*"
        }
        It 'leaves a new credential with another name alone and says so' {
            $fx = $global:OnboardingFixture
            $adds = { param([string]$ApplicationId, [securestring]$Secret) $global:OnboardingFixture.keys += 'dddddddd-dddd-dddd-dddd-dddddddddddd'; $global:OnboardingFixture.keyNames['dddddddd-dddd-dddd-dddd-dddddddddddd'] = 'added-by-hand' }
            Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $adds | Out-Null
            $fx.keys | Should -Be @('dddddddd-dddd-dddd-dddd-dddddddddddd')
            ($fx.messages -join "`n") | Should -Match 'not named rbac; they are left alone: added-by-hand'
        }
        It 'refuses two applications with the name before it creates anything' {
            $fx = $global:OnboardingFixture
            $fx.apps = @(@{ appId = '44444444-4444-4444-4444-444444444444'; keys = @() }, @{ appId = '77777777-7777-7777-7777-777777777777'; keys = @() })
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } | Should -Throw '*Ambiguous onboarding application name*'
            $fx.events | Should -Not -Contain 'sp-create'
        }
    }

    Context 'preconditions' {
        It 'refuses an ambiguous service principal name before any change' {
            $fx = $global:OnboardingFixture
            $fx.sps = @(@{ id = '55555555-5555-5555-5555-555555555555'; appId = '44444444-4444-4444-4444-444444444444' }, @{ id = '66666666-6666-6666-6666-666666666666'; appId = '77777777-7777-7777-7777-777777777777' })
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } | Should -Throw '*Ambiguous onboarding service principal*'
            $fx.events | Should -Not -Contain 'role-create'
            $fx.events | Should -Not -Contain 'mint'
        }
        It 'refuses to grant the role before the Arc group exists' {
            $fx = $global:OnboardingFixture
            $fx.rgExists = $false
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } | Should -Throw '*rg-fixture does not exist yet*'
            $fx.events | Should -Not -Contain 'sp-list'
            $fx.events | Should -Not -Contain 'role-create'
        }
        It 'requires the explicit demo context first' {
            InModuleScope Common { $script:DemoSubscription = $null }
            { Initialize-DemoOnboardingIdentity -NamePrefix fixture -ResourceGroup rg-fixture -Action $script:deliver } | Should -Throw '*Initialize the explicit demo context*'
        }
    }
}

Describe 'Deploy phases 4 to 5.5 run inside the onboarding identity helper' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:deployScript, [ref]$null, [ref]$null)
        $assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$onboardArcMachines' }, $true)
        $invocation = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$toOnboardFleet.Count' }, $true)
        $script:onboardPhases = $assignment.Extent.Text + "`n" + $invocation.Extent.Text
        function Get-ArcMachineTags { param($Machine, $BaseTags) [ordered]@{ fixture = '1' } }
    }
    BeforeEach {
        New-OnboardingFixture
        InModuleScope Common {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $script:DemoTenant = '22222222-2222-2222-2222-222222222222'
        }
        Mock Invoke-DemoAz -ModuleName Common -MockWith $script:fakeAz
        Mock Start-Sleep -ModuleName Common { $global:OnboardingFixture.sleeps.Add([int]$Seconds) }
        Mock Write-Ok -ModuleName Common {}
        Mock Write-Step -ModuleName Common {}
        Mock Write-Warn -ModuleName Common {}
        Mock Write-Header {}
        Mock Write-Ok {}
        Mock Write-Step {}
        Mock Write-Warn {}
        Mock Wait-Until { $true }
        Mock Wait-DemoJobs {}
        Mock az { $global:OnboardingFixture.events.Add("az $($args[0]) $($args[1])") }
        Mock Set-DemoResourceTags { $true }
        Mock Invoke-DemoGuestCommand {
            $fx = $global:OnboardingFixture
            if ($null -ne $Job) {
                $fx.events.Add('guest-result')
                if ($Job.Fail) { throw "Guest command failed on $($Machine.Name)" }
                return
            }
            $fx.events.Add('guest-command')
            $path = $Script.Substring(1)
            $fx.guestScripts.Add(@{ Machine = $Machine.Name; OsType = $Machine.OsType; Path = $path; Text = (Get-Content -LiteralPath $path -Raw) })
            [pscustomobject]@{ Name = "vm-run-command-$($Machine.Name)"; State = 'Completed'; Fail = ($fx.failGuestOn -split ',' -contains $Machine.Name) }
        }
        $NamePrefix = 'fixture'; $arcRg = 'rg-fixture'; $infraRg = 'rg-fixture-infra'
        $SubscriptionId = '11111111-1111-1111-1111-111111111111'; $TenantId = '22222222-2222-2222-2222-222222222222'
        $Location = 'australiaeast'; $arcOnboardingTags = 'demo=fixture'; $demoTags = @{}; $OnboardingSecret = $null
        $deployedFleet = @(
            [pscustomobject]@{ name = 'vm-win'; osType = 'Windows' }
            [pscustomobject]@{ name = 'vm-lnx'; osType = 'Linux' }
        )
        $vmNames = @($deployedFleet.name)
        $toOnboardFleet = $deployedFleet
    }

    It 'onboards without a supplied secret using a credential that exists only while the machines onboard' {
        $fx = $global:OnboardingFixture
        & ([scriptblock]::Create($script:onboardPhases))
        $steps = @($fx.events | Where-Object { $_ -in 'role-create', 'mint', 'guest-command', 'cleanup' })
        $steps -join ',' | Should -Be 'role-create,mint,guest-command,guest-command,cleanup'
        $fx.keys | Should -Be @($fx.baselineKey)
        $linux = $fx.guestScripts | Where-Object OsType -eq 'Linux'
        $windows = $fx.guestScripts | Where-Object OsType -eq 'Windows'
        $linux.Text | Should -Match "--service-principal-id 44444444-4444-4444-4444-444444444444 --service-principal-secret 'Synthetic-Onboarding-Secret-7419'"
        $windows.Text | Should -Match "--service-principal-id 44444444-4444-4444-4444-444444444444 --service-principal-secret 'Synthetic-Onboarding-Secret-7419'"
        Test-Path -LiteralPath $linux.Path | Should -BeFalse
        # Only the two periodic-assessment updates still use az; the tags go through the ARM tags API.
        Should -Invoke az -Times 2 -Exactly
        Should -Invoke Set-DemoResourceTags -Times 1 -Exactly -ParameterFilter { $ResourceId -eq '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines/vm-win' }
        Should -Invoke Set-DemoResourceTags -Times 1 -Exactly -ParameterFilter { $ResourceId -like '*/machines/vm-lnx' -and $Tags['fixture'] -eq '1' }
    }
    It 'uses a supplied secret as is and mints nothing' {
        $fx = $global:OnboardingFixture
        $OnboardingSecret = ConvertTo-SecureString 'Synthetic-Supplied-Secret-5521' -AsPlainText -Force
        & ([scriptblock]::Create($script:onboardPhases))
        $fx.events | Should -Not -Contain 'mint'
        $fx.events | Should -Not -Contain 'graph-get'
        $fx.events | Should -Contain 'role-create'
        ($fx.guestScripts | Where-Object OsType -eq 'Linux').Text | Should -Match "--service-principal-secret 'Synthetic-Supplied-Secret-5521'"
    }
    It 'creates the service principal on a first deployment and mints nothing' {
        $fx = $global:OnboardingFixture
        $fx.sps = @()
        & ([scriptblock]::Create($script:onboardPhases))
        $fx.events | Should -Contain 'sp-create'
        $fx.events | Should -Not -Contain 'mint'
        ($fx.guestScripts | Where-Object OsType -eq 'Linux').Text | Should -Match "--service-principal-secret 'Synthetic-Created-Secret-3306'"
    }
    It 'removes the credential and the script files when a machine fails to onboard' {
        $fx = $global:OnboardingFixture
        $fx.failGuestOn = 'vm-lnx'
        { & ([scriptblock]::Create($script:onboardPhases)) } | Should -Throw '*Arc onboarding failed on 1 of 2 VM(s): vm-lnx: Guest command failed on vm-lnx*'
        ($fx.events | Where-Object { $_ -in 'mint', 'guest-command', 'cleanup' }) -join ',' | Should -Be 'mint,guest-command,guest-command,cleanup'
        $fx.keys | Should -Be @($fx.baselineKey)
        $fx.guestScripts | ForEach-Object { Test-Path -LiteralPath $_.Path | Should -BeFalse }
    }
    It 'submits every machine before it waits for any, and receives each result' {
        $fx = $global:OnboardingFixture
        & ([scriptblock]::Create($script:onboardPhases))
        ($fx.events | Where-Object { $_ -in 'guest-command', 'guest-result' }) -join ',' | Should -Be 'guest-command,guest-command,guest-result,guest-result'
        Should -Invoke Wait-DemoJobs -Times 1 -Exactly -ParameterFilter { @($Jobs).Count -eq 2 -and $TimeoutSeconds -eq 900 }
        Should -Invoke Invoke-DemoGuestCommand -Times 2 -Exactly -ParameterFilter { $AsJob }
        Should -Invoke Invoke-DemoGuestCommand -Times 2 -Exactly -ParameterFilter { $Job -and $TimeoutSeconds -eq 30 }
    }
    It 'names every VM that failed to onboard, not only the first, and still receives the others' {
        $fx = $global:OnboardingFixture
        $fx.failGuestOn = 'vm-win,vm-lnx'
        { & ([scriptblock]::Create($script:onboardPhases)) } | Should -Throw '*Arc onboarding failed on 2 of 2 VM(s): vm-win: Guest command failed on vm-win | vm-lnx: Guest command failed on vm-lnx*'
        @($fx.events | Where-Object { $_ -eq 'guest-result' }).Count | Should -Be 2
        $fx.keys | Should -Be @($fx.baselineKey)
    }
    It 'needs no identity when every machine is already Arc-onboarded' {
        $fx = $global:OnboardingFixture
        $toOnboardFleet = @()
        & ([scriptblock]::Create($script:onboardPhases))
        $fx.events | Should -Not -Contain 'group-exists'
        $fx.events | Should -Not -Contain 'mint'
        $fx.guestScripts.Count | Should -Be 0
        Should -Invoke az -Times 2 -Exactly
    }
}
