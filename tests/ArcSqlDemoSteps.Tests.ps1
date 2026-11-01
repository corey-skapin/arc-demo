BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\Common.psm1')
    $script:install = Join-Path $PSScriptRoot '..\scripts\Install-ArcSqlDemoExtension.ps1'
    $script:inventory = Join-Path $PSScriptRoot '..\scripts\Test-ArcSqlDemoInventory.ps1'
}

Describe 'Simple Arc SQL inventory steps' {
    BeforeEach {
        Mock Import-Module {}
        Mock Initialize-DemoContext {}
        $script:target = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            TenantId = '22222222-2222-2222-2222-222222222222'
            ResourceGroup = 'rg-demo'
            ArcName = 'DEMOSQL'
        }
        Mock Invoke-AzRest {
            if ($Method -ne 'Get') { throw 'Unexpected write' }
            if ($Url -like '*/databases?*') {
                return @{value=@(@{name='master';properties=@{state='Online'}})}
            }
            if ($Url -like '*/sqlServerInstances/*') {
                return @{id='SYNTHETIC-SQL-ID';properties=@{
                    status='Connected';containerResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/DEMOSQL'
                    edition='Developer';currentVersion='16.0.1000.6'
                }}
            }
            if ($Url -like '*/extensions/*') {
                return @{properties=@{
                    provisioningState='Succeeded'
                    settings=@{LicenseType='LicenseOnly'}
                }}
            }
            return @{id='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/DEMOSQL';tags=@{ArcSQLServerExtensionDeployment='Disabled'};properties=@{status='Connected'}}
        }
    }

    It 'reuses a succeeded LicenseOnly extension without a write' {
        $result = & $script:install @script:target -Location australiaeast -Confirm:$false
        $result.properties.provisioningState | Should -Be Succeeded
        Should -Invoke Invoke-AzRest -Times 0 -ParameterFilter { $Method -ne 'Get' }
    }

    It 'does not silently change existing pricing' {
        Mock Invoke-AzRest { @{properties=@{provisioningState='Succeeded';settings=@{LicenseType='PAYG'}}} } -ParameterFilter { $Url -like '*/extensions/*' }
        { & $script:install @script:target -Location australiaeast -Confirm:$false } |
            Should -Throw '*licensing differs*'
        Should -Invoke Invoke-AzRest -Times 0 -ParameterFilter { $Method -ne 'Get' }
    }

    It 'previews extension installation without a write' {
        Mock Invoke-AzRest { @{properties=@{provisioningState='Failed'}} } -ParameterFilter { $Url -like '*/extensions/*' }
        & $script:install @script:target -Location australiaeast -WhatIf
        Should -Invoke Invoke-AzRest -Times 0 -ParameterFilter { $Method -ne 'Get' }
    }

    It 'waits through a typed 404 after accepted creation without repeating the PUT' {
        $script:extensionReads = 0
        Mock Invoke-AzRest { @{} } -ParameterFilter { $Method -eq 'Put' }
        Mock Invoke-AzRest {
            $script:extensionReads++
            if ($script:extensionReads -eq 1) { return @{properties=@{provisioningState='Failed'}} }
            if ($script:extensionReads -eq 2) {
                $failure = [Exception]::new('Not Found')
                $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=404})
                throw $failure
            }
            @{properties=@{provisioningState='Succeeded';settings=@{LicenseType='LicenseOnly'}}}
        } -ParameterFilter { $Method -eq 'Get' -and $Url -like '*/extensions/*' }
        Mock Wait-Until {
            (& $Condition) | Should -BeFalse
            (& $Condition) | Should -BeTrue
        }
        $result = & $script:install @script:target -Location australiaeast -Confirm:$false
        $result.properties.provisioningState | Should -Be Succeeded
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter { $Method -eq 'Put' }
    }

    It 'does not treat a denied provisioning poll as pending or repeat the PUT' {
        $script:extensionReads = 0
        Mock Invoke-AzRest { @{} } -ParameterFilter { $Method -eq 'Put' }
        Mock Invoke-AzRest {
            $script:extensionReads++
            if ($script:extensionReads -eq 1) { return @{properties=@{provisioningState='Failed'}} }
            $failure = [Exception]::new('Forbidden')
            $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=403})
            throw $failure
        } -ParameterFilter { $Method -eq 'Get' -and $Url -like '*/extensions/*' }
        Mock Wait-Until { & $Condition }
        { & $script:install @script:target -Location australiaeast -Confirm:$false } | Should -Throw '*Forbidden*'
        Should -Invoke Invoke-AzRest -Times 1 -ParameterFilter { $Method -eq 'Put' }
    }

    It 'returns actual database inventory rather than a local-service proxy' {
        $result = & $script:inventory @script:target -SqlResourceName DEMOSQL
        $result.SqlStatus | Should -Be Connected
        $result.Databases[0].name | Should -Be master
        $result.Databases[0].State | Should -Be Online
        Should -Invoke Invoke-AzRest -Times 4
    }

    It 'rejects SQL inventory attached to another Arc machine' {
        Mock Invoke-AzRest { @{properties=@{status='Connected';containerResourceId='SYNTHETIC-OTHER-MACHINE'}} } -ParameterFilter { $Url -like '*/sqlServerInstances/*' }
        { & $script:inventory @script:target -SqlResourceName DEMOSQL } |
            Should -Throw '*did not all pass*'
    }

    It 'surfaces denied reads without reporting inventory success' {
        Mock Invoke-AzRest { throw 'AuthorizationFailed' }
        { & $script:inventory @script:target -SqlResourceName DEMOSQL } |
            Should -Throw '*AuthorizationFailed*'
        Should -Invoke Invoke-AzRest -Times 1
    }
}
