BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts/lib/Common.psm1')
    $deploy = Join-Path $repo 'scripts/Deploy-ArcDemo.ps1'
    $target = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222' }

    # Azure CLI 2.91 output with synthetic identifiers. The enabled plan has the extension state that a Defender for
    # Servers P2 subscription with agentless scanning reports; a PUT without `extensions` shows as Delete properties.extensions.
    $enabledPlan = @'
{
  "deprecated": null,
  "enablementTime": "2026-01-15T00:00:00.000000+00:00",
  "extensions": [
    { "additionalExtensionProperties": null, "isEnabled": "False", "name": "MdeDesignatedSubscription", "operationStatus": null },
    { "additionalExtensionProperties": { "ExclusionTags": "[]" }, "isEnabled": "True", "name": "AgentlessVmScanning", "operationStatus": null },
    { "additionalExtensionProperties": null, "isEnabled": "False", "name": "FileIntegrityMonitoring", "operationStatus": null }
  ],
  "freeTrialRemainingTime": "0:00:00",
  "id": "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Security/pricings/VirtualMachines",
  "name": "VirtualMachines",
  "pricingTier": "Standard",
  "replacedBy": null,
  "subPlan": "P2",
  "type": "Microsoft.Security/pricings"
}
'@
    # What a subscription that never enabled the plan (or disabled it with Remove -DisableDefender) returns.
    $freePlan = @'
{
  "deprecated": null,
  "enablementTime": null,
  "extensions": null,
  "freeTrialRemainingTime": "30 days, 0:00:00",
  "id": "/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Security/pricings/VirtualMachines",
  "name": "VirtualMachines",
  "pricingTier": "Free",
  "replacedBy": null,
  "subPlan": null,
  "type": "Microsoft.Security/pricings"
}
'@
}

Describe 'Deploy leaves an enabled Defender for Servers plan alone' {
    BeforeEach {
        Mock Import-Module {}
        Mock Write-Step {}
        Mock Write-Header {}
        Mock Write-Ok {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        $state = @{ plan = $enabledPlan; denied = $false; preview = $null }
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'security') {
                if ($state.denied) { throw 'Azure CLI security pricing failed (exit 1): (AuthorizationFailed) The client does not have authorization to perform action ''Microsoft.Security/pricings/read'' over scope ''/subscriptions/11111111-1111-1111-1111-111111111111/providers/Microsoft.Security/pricings/VirtualMachines''.' }
                return $state.plan
            }
            # A clean subscription: the infra group does not exist, so every -AllowNotFound read returns $null.
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption', 'aks', 'containerapp', 'vm')) { return $null }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -eq 'bicep') { return '{"parameters":{"onPremFleet":{"defaultValue":[]}}}' }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $state.preview = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                return
            }
            throw "Unexpected operation: $($Arguments -join ' ')"
        }
    }

    It 'skips the plan when Standard P2 with agentless scanning is already enabled, and reads only that plan' {
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.deployDefenderVmPlan.value | Should -BeFalse
        Should -Invoke Write-Step -Times 1 -Exactly -ParameterFilter { $Message -like 'Found enabled Defender for Servers plan (Standard P2)*untouched' }
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'security' }
        Should -Invoke Invoke-DemoAz -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'security' -and $Arguments[1] -eq 'pricing' -and $Arguments[2] -eq 'show' -and $Arguments[4] -eq 'VirtualMachines'
        }
    }
    It 'also leaves a Standard P1 plan unchanged instead of upgrading it' {
        $state.plan = $enabledPlan.Replace('"subPlan": "P2"', '"subPlan": "P1"')
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.deployDefenderVmPlan.value | Should -BeFalse
        Should -Invoke Write-Step -Times 1 -Exactly -ParameterFilter { $Message -like 'Found enabled Defender for Servers plan (Standard P1)*untouched' }
    }
    It 'treats a Standard plan without a subplan as enabled' {
        $state.plan = $enabledPlan.Replace('"subPlan": "P2"', '"subPlan": null')
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.deployDefenderVmPlan.value | Should -BeFalse
        Should -Invoke Write-Step -Times 1 -Exactly -ParameterFilter { $Message -like 'Found enabled Defender for Servers plan (Standard)*untouched' }
    }
    It 'enables the plan on a fresh subscription or after Remove -DisableDefender (Free tier)' {
        $state.plan = $freePlan
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $state.preview.parameters.deployDefenderVmPlan.value | Should -BeTrue
        Should -Invoke Write-Step -Times 0 -ParameterFilter { $Message -like '*Found enabled Defender*' }
    }
    It 'never writes a Defender plan itself; the template is the only writer' {
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'security' -and $Arguments[2] -ne 'show' }
    }
    It 'refuses to guess when the plan state is <Name>' -ForEach @(
        @{ Name = 'empty'; Plan = $null }
        @{ Name = 'missing its tier'; Plan = '{"name":"VirtualMachines","subPlan":"P2"}' }
        @{ Name = 'an unknown tier'; Plan = '{"name":"VirtualMachines","pricingTier":"Basic"}' }
    ) {
        $state.plan = $Plan
        { & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf } | Should -Throw '*Cannot read the Defender for Servers plan tier*az security pricing show --name VirtualMachines*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
    }
    It 'surfaces a denied read and previews nothing' {
        $state.denied = $true
        { & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf } | Should -Throw '*AuthorizationFailed*Microsoft.Security/pricings/read*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
    }
    It 'passes only parameters that main.bicep declares' {
        & $deploy @target -NamePrefix fixture -AdminEmail 'test@example.com' -WhatIf
        $declared = @([regex]::Matches((Get-Content -LiteralPath (Join-Path $repo 'bicep/main.bicep') -Raw), '(?m)^param\s+(\w+)\s') | ForEach-Object { $_.Groups[1].Value })
        $passed = @($state.preview.parameters.PSObject.Properties.Name)
        $passed | Should -Contain 'deployDefenderVmPlan'
        @($passed | Where-Object { $_ -cnotin $declared }) | Should -BeNullOrEmpty
    }
}

Describe 'Defender for Servers plan template' {
    BeforeAll {
        $main = Get-Content -LiteralPath (Join-Path $repo 'bicep/main.bicep') -Raw
        $module = (Get-Content -LiteralPath (Join-Path $repo 'bicep/modules/defender.bicep') | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    }
    It 'enables the plan by default, so a direct deployment to a fresh subscription still works' {
        $main | Should -Match '(?m)^param deployDefenderVmPlan bool = true\s*$'
    }
    It 'deploys the module only while the plan is not already enabled' {
        $main | Should -Match "module defenderMod 'modules/defender\.bicep' = if \(deployDefenderVmPlan\) \{"
    }
    It 'declares only the VirtualMachines plan, so no other plan is touched' {
        @([regex]::Matches($module, 'Microsoft\.Security/pricings@')).Count | Should -Be 1
        $module | Should -Match "name: 'VirtualMachines'"
        $module | Should -Match "pricingTier: 'Standard'"
        $module | Should -Match "subPlan: 'P2'"
    }
    It 'declares no extensions, which is why it must never be applied to an enabled plan' {
        $module | Should -Not -Match 'extensions'
    }
}
