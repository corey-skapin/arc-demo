BeforeAll {
    $script:remove=Join-Path $PSScriptRoot '..\scripts\Remove-NestedSqlDemoGuest.ps1'
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        function Get-VM { param($Name) }
        function Get-VMHardDiskDrive { param($VM) }
        function Remove-VM { param($VM,[switch]$Force) }
    }
}
Describe 'Exact Arc removal boundary' {
        BeforeAll {
            Import-Module (Join-Path $PSScriptRoot '..\scripts\lib\Common.psm1')
            $script:cloudRemove=Join-Path $PSScriptRoot '..\scripts\Remove-NestedSqlDemo.ps1'
        }
        BeforeEach {
            Mock Import-Module {}
            Mock Initialize-DemoContext {}
            Mock Invoke-AzRest { throw 'No cloud write expected' }
            $script:ids=@{
                SubscriptionId='11111111-1111-1111-1111-111111111111';TenantId='22222222-2222-2222-2222-222222222222'
                ParentResourceGroup='rg-demo-infra';ParentVmName='parent';ParentVmId='33333333-3333-3333-3333-333333333333'
                VmName='DemoNew';VmId='44444444-4444-4444-4444-444444444444';VmRoot='D:\NestedSQL\VMs\DemoNew'
                ArcAgentVmId='55555555-5555-5555-5555-555555555555'
                ArcMachineId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/DemoNew'
                SqlInstanceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-demo/providers/Microsoft.AzureArcData/sqlServerInstances/DemoNew'
            }
        }
        It 'rejects a SQL ID outside this exact guest before cloud calls' {
            $script:ids.SqlInstanceId=$script:ids.SqlInstanceId.Replace('DemoNew','OtherGuest')
            { & $script:cloudRemove @script:ids -Confirm:$false } | Should -Throw '*SQL instance ID differs*'
            Should -Invoke Invoke-AzRest -Times 0
        }
        It 'rejects a different subscription before cloud calls' {
            $script:ids.ArcMachineId=$script:ids.ArcMachineId.Replace('11111111-1111-1111-1111-111111111111','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
            { & $script:cloudRemove @script:ids -Confirm:$false } | Should -Throw '*subscription and guest name*'
            Should -Invoke Invoke-AzRest -Times 0
        }
        It 'surfaces an access denial without any delete' {
            Mock Invoke-AzRest { throw 'AuthorizationFailed' }
            { & $script:cloudRemove @script:ids -Confirm:$false } | Should -Throw '*AuthorizationFailed*'
            Should -Invoke Invoke-AzRest -Times 0 -ParameterFilter { $Method -ne 'Get' }
        }
    }
Describe 'Exact nested guest deletion boundary' {
    BeforeEach {
        Mock Get-VM { [pscustomobject]@{Name='DemoNew';VMId=[guid]'11111111-2222-3333-4444-555555555555';Path='D:\NestedSQL\VMs\DemoNew\DemoNew'} }
        Mock Get-VMHardDiskDrive {
            [pscustomobject]@{Path='D:\NestedSQL\VMs\DemoNew\DemoNew-OS.vhdx'}
            [pscustomobject]@{Path='D:\NestedSQL\VMs\DemoNew\DemoNew-SQLData.vhdx'}
        }
        Mock Remove-VM { throw 'No deletion expected' }
        Mock Remove-Item { throw 'No deletion expected' }
    }
    It 'rejects the old guest before Hyper-V or deletion' {
        { & $script:remove -VmName NestedSqlGuest -VmId '11111111-2222-3333-4444-555555555555' -VmRoot D:\NestedSQL\VMs\NestedSqlGuest } | Should -Throw '*explicitly identified*'
        Should -Invoke Get-VM -Times 0
        Should -Invoke Remove-Item -Times 0
    }
    It 'rejects a root that includes shared storage' {
        { & $script:remove -VmName DemoNew -VmId '11111111-2222-3333-4444-555555555555' -VmRoot D:\NestedSQL } | Should -Throw '*explicitly identified*'
        Should -Invoke Remove-Item -Times 0
    }
    It 'rejects a stale guest GUID before deletion' {
        { & $script:remove -VmName DemoNew -VmId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -VmRoot D:\NestedSQL\VMs\DemoNew } | Should -Throw '*GUID*'
        Should -Invoke Remove-VM -Times 0
        Should -Invoke Remove-Item -Times 0
    }
    It 'rejects a different disk path before deletion' {
        Mock Get-VMHardDiskDrive { [pscustomobject]@{Path='D:\NestedSQL\VMs\Other\Other-OS.vhdx'} }
        { & $script:remove -VmName DemoNew -VmId '11111111-2222-3333-4444-555555555555' -VmRoot D:\NestedSQL\VMs\DemoNew } | Should -Throw '*disk paths*'
        Should -Invoke Remove-VM -Times 0
        Should -Invoke Remove-Item -Times 0
    }
}
