BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\Common.psm1')
    $script:transport=Join-Path $PSScriptRoot '..\scripts\Invoke-NestedSqlDemoStep.ps1'
}
Describe 'Nested demo noninteractive protected transport' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        Mock Start-Sleep {}
        Mock Invoke-AzRest {
            if ($Method -eq 'Put') { return }
            if ($Url -like '*runCommands/*') {
                return @{id='SYNTHETIC-COMMAND';properties=@{instanceView=@{executionState='Succeeded';exitCode=0;output='done'}}}
            }
            if ($Url -like '*runCommands?*') { return @{value=@()} }
            return @{
                id='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo/providers/Microsoft.Compute/virtualMachines/parent'
                location='australiaeast';properties=@{vmId='33333333-3333-3333-3333-333333333333'}
            }
        }
    }
    It 'propagates the approved noninteractive decision into the remote step' {
        & $script:transport -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' -ParentResourceGroup rg-demo -ParentVmName parent `
            -ParentVmId '33333333-3333-3333-3333-333333333333' -Step Remove `
            -Parameters @{VmName='DemoNew';VmRoot='D:\NestedSQL\VMs\DemoNew';VmId='44444444-4444-4444-4444-444444444444'} `
            -Confirm:$false | Out-Null
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter {
            $Method -eq 'Put' -and
            $Body.properties.source.script.Contains("if ('Remove' -ne 'Test') { `$arguments.Confirm=`$false }")
        }
    }

    It 'places the onboarding secret only in Connect protected parameters' {
        $guestSecret = ConvertTo-SecureString 'Synthetic!Credential12345678901234567890' -AsPlainText -Force
        $onboardingSecret = ConvertTo-SecureString 'Transport-Sentinel-Secret-7419' -AsPlainText -Force
        $guestCredential = [pscredential]::new('Administrator',$guestSecret)
        try {
            & $script:transport -SubscriptionId '11111111-1111-1111-1111-111111111111' `
                -TenantId '22222222-2222-2222-2222-222222222222' -ParentResourceGroup rg-demo -ParentVmName parent `
                -ParentVmId '33333333-3333-3333-3333-333333333333' -Step Connect `
                -Parameters @{VmName='DemoNew';GuestAddress='172.31.240.20';OnboardingApplicationId='44444444-4444-4444-4444-444444444444'} `
                -GuestCredential $guestCredential -OnboardingSecret $onboardingSecret -Confirm:$false | Out-Null
            Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter {
                if ($Method -ne 'Put') { return $false }
                $protected = @($Body.properties.protectedParameters)
                $names = @($protected | ForEach-Object name)
                $source = $Body.properties.source.script
                $ordinary = [string]($Body.properties.parameters | ConvertTo-Json -Compress)
                ('GuestPassword' -in $names) -and ('OnboardingSecretValue' -in $names) -and
                    (($protected | Where-Object name -eq 'OnboardingSecretValue').value -eq 'Transport-Sentinel-Secret-7419') -and
                    -not $source.Contains('Transport-Sentinel-Secret-7419') -and
                    -not $ordinary.Contains('Transport-Sentinel-Secret-7419')
            }
        } finally {
            $guestSecret.Dispose()
            $onboardingSecret.Dispose()
        }
    }
}
