BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers'
    function New-PreviewMachine {
        param([string]$Name, [string]$PowerState)
        [pscustomobject]@{ Name = $Name; Id = "$script:root/Microsoft.Compute/virtualMachines/$Name"; Actual = [pscustomobject]@{ powerState = $PowerState } }
    }
}

Describe 'Hibernate preview lines' {
    BeforeEach {
        $script:revisionJson = '[{"name":"app--0000002","properties":{"active":true}},{"name":"app--0000001","properties":{"active":false}}]'
        Mock Invoke-DemoAz -ModuleName Common { $script:revisionJson } -ParameterFilter { $Arguments[0] -eq 'containerapp' -and $Arguments[2] -eq 'list' }
        $script:inventory = [pscustomobject]@{
            InfraRg = 'rg-fixture-infra'
            Machines = @((New-PreviewMachine 'win-app-01' 'VM running'), (New-PreviewMachine 'lnx-app-01' 'VM deallocated'), (New-PreviewMachine 'sql-parent' 'VM running'))
            AksClusterIds = @("$script:root/Microsoft.ContainerService/managedClusters/aks-fixture")
            ContainerAppIds = @("$script:root/Microsoft.App/containerApps/ca-fixture")
        }
        $script:network = [pscustomobject]@{
            SafeToRemove = $true; ConflictMessage = ''
            NatId = "$script:root/Microsoft.Network/natGateways/natgw-fixture"; PublicIpId = "$script:root/Microsoft.Network/publicIPAddresses/pip-natgw-fixture"
            Nat = @{ id = 'nat' }; PublicIp = @{ id = 'pip' }
            Subnet = @{ natGateway = @{ id = "$script:root/Microsoft.Network/natGateways/natgw-fixture" } }
        }
        $script:guest = [pscustomobject]@{ ParentVmName = 'sql-parent'; GuestVmName = 'sql-guest'; ArcMachineName = 'sql-guest' }
    }

    It 'says what each workload would do instead of one generic sentence' {
        $lines = @(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $script:guest -Network $script:network)
        $lines[0] | Should -BeLike 'Nested SQL guest sql-guest: stopped gracefully first, through Run Command on its parent sql-parent*'
        $lines | Should -Contain 'VM win-app-01: VM running -> deallocate (submitted without waiting).'
        $lines | Should -Contain 'VM lnx-app-01: VM deallocated, already parked.'
        $lines | Should -Contain 'VM sql-parent: VM running -> deallocate (submitted without waiting).'
        $lines | Should -Contain 'AKS aks-fixture: stopped if it is running.'
        $lines | Should -Contain 'Container App ca-fixture: active revision(s) app--0000002 -> deactivate.'
        $lines | Should -Contain 'Network: after compute has stopped, removed in this order: the subnet association, NAT gateway natgw-fixture, public IP pip-natgw-fixture.'
        $lines[-1] | Should -BeLike 'Then: the Hibernated readiness check runs*'
        Should -Invoke Invoke-DemoAz -ModuleName Common -Times 1 -Exactly
    }

    It 'sends no stop command to a nested guest whose parent is not running, and says why' {
        $script:inventory.Machines[2].Actual.powerState = 'VM deallocated'
        $lines = @(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $script:guest -Network $script:network)
        $lines[0] | Should -Be 'Nested SQL guest sql-guest: no stop command, its parent sql-parent is VM deallocated.'
    }

    It 'reports a network it leaves alone, an absent one and one that was not read' {
        $script:network.SafeToRemove = $false; $script:network.ConflictMessage = 'Demo NAT Gateway is shared with another subnet.'
        (@(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $null -Network $script:network) | Where-Object { $_ -like 'Network:*' }) |
            Should -Be 'Network: left alone (Demo NAT Gateway is shared with another subnet.) NAT/PIP costs may remain.'
        $script:network.SafeToRemove = $true; $script:network.Nat = $null; $script:network.PublicIp = $null; $script:network.Subnet = $null
        (@(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $null -Network $script:network) | Where-Object { $_ -like 'Network:*' }) |
            Should -Be 'Network: no NAT association, NAT gateway or public IP to remove.'
        (@(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $null -Network $null) | Where-Object { $_ -like 'Network:*' }) | Should -Be 'Network: not inspected.'
    }

    It 'says so when the revisions of a Container App cannot be read, and still lists everything else' {
        Mock Invoke-DemoAz -ModuleName Common { throw 'AuthorizationFailed: revisions' } -ParameterFilter { $Arguments[0] -eq 'containerapp' }
        $lines = @(Get-DemoParkPreview -Inventory $script:inventory -NestedSqlGuest $null -Network $script:network)
        $lines | Should -Contain 'Container App ca-fixture: revisions could not be read (AuthorizationFailed: revisions).'
        $lines | Should -Contain 'VM win-app-01: VM running -> deallocate (submitted without waiting).'
    }
}

Describe 'Activate preview lines' {
    BeforeEach {
        $script:revisionJson = '[{"name":"app--0000001","properties":{"active":false}}]'
        Mock Invoke-DemoAz -ModuleName Common { $script:revisionJson } -ParameterFilter { $Arguments[0] -eq 'containerapp' -and $Arguments[2] -eq 'list' }
        $script:inventory = [pscustomobject]@{
            InfraRg = 'rg-fixture-infra'
            Machines = @((New-PreviewMachine 'win-app-01' 'VM deallocated'), (New-PreviewMachine 'lnx-app-01' 'VM running'), (New-PreviewMachine 'win-app-02' 'VM starting'))
            ParkedMachines = @([pscustomobject]@{ Name = 'image-parent'; Id = 'x'; KeepParked = $true })
            AksClusterIds = @("$script:root/Microsoft.ContainerService/managedClusters/aks-fixture")
            ContainerAppIds = @("$script:root/Microsoft.App/containerApps/ca-fixture")
        }
        $script:network = [pscustomobject]@{
            NatId = "$script:root/Microsoft.Network/natGateways/natgw-fixture"; PublicIpId = "$script:root/Microsoft.Network/publicIPAddresses/pip-natgw-fixture"
            Nat = $null; PublicIp = $null; Subnet = @{ natGateway = $null }
        }
        $script:guest = [pscustomobject]@{ ParentVmName = 'sql-parent'; GuestVmName = 'sql-guest'; ArcMachineName = 'sql-guest' }
    }

    It 'lists the network it would restore, each VM with what happens to it, and the guest, AKS and app steps' {
        $lines = @(Get-DemoWakePreview -Inventory $script:inventory -NestedSqlGuest $script:guest -Network $script:network -GuestCheckMinutes 20)
        $lines[0] | Should -Be 'Public IP pip-natgw-fixture: absent -> created (Standard, static) before any VM starts.'
        $lines[1] | Should -Be 'NAT gateway natgw-fixture: absent -> created with that public IP.'
        $lines | Should -Contain 'Subnet snet-vms: attached to the NAT gateway.'
        $lines | Should -Contain 'The NAT gateway and public IP carry the lab tags (owner, purpose, costcenter, env and the skin''s own).'
        $lines | Should -Contain 'VM win-app-01: VM deallocated -> start.'
        $lines | Should -Contain 'VM lnx-app-01: running, left alone.'
        $lines | Should -Contain 'VM win-app-02: already starting, waited for.'
        $lines | Should -Contain 'VM image-parent: kept deallocated (operations.keepParkedVmNames); never started.'
        ($lines | Where-Object { $_ -like 'Nested SQL guest sql-guest: started through Run Command on its parent sql-parent*' }) | Should -Not -BeNullOrEmpty
        $lines | Should -Contain 'AKS aks-fixture: started if it is stopped.'
        $lines | Should -Contain 'Container App ca-fixture: no active revision -> its latest revision is activated; no fault reset.'
        $lines[-1] | Should -BeLike 'Then one shared wait of up to 20 minutes for every host*'
    }

    It 'says present for a NAT gateway and public IP that exist and attached for a subnet that already points at it' {
        $script:network.Nat = @{ id = 'nat' }; $script:network.PublicIp = @{ id = 'pip' }
        $script:network.Subnet = @{ natGateway = @{ id = $script:network.NatId } }
        $lines = @(Get-DemoWakePreview -Inventory $script:inventory -NestedSqlGuest $null -Network $script:network)
        $lines[0] | Should -Be 'Public IP pip-natgw-fixture: present.'
        $lines[1] | Should -Be 'NAT gateway natgw-fixture: present.'
        $lines[2] | Should -Be 'Subnet snet-vms: already attached to the NAT gateway.'
    }

    It 'leaves an active Container App revision alone' {
        $script:revisionJson = '[{"name":"app--0000003","properties":{"active":true}}]'
        $lines = @(Get-DemoWakePreview -Inventory $script:inventory -NestedSqlGuest $null -Network $script:network)
        $lines | Should -Contain 'Container App ca-fixture: active revision(s) app--0000003 left alone; no fault reset.'
    }
}

Describe 'Pipelines that must survive -WhatIf' {
    # ForEach-Object <member> asks ShouldProcess for every object it reads, so under -WhatIf it prints a line per object
    # and returns nothing, in this module's functions too. The script-block form does not.
    It 'keeps the AKS and Container App IDs of the hibernation inventory when a script runs with -WhatIf' {
        $aksId = "$script:root/Microsoft.ContainerService/managedClusters/aks-fixture"
        $appId = "$script:root/Microsoft.App/containerApps/ca-fixture"
        $resourcesPath = Join-Path $TestDrive 'resources.json'
        ConvertTo-Json -InputObject @(
            @{ id = $aksId; type = 'Microsoft.ContainerService/managedClusters'; name = 'aks-fixture' }
            @{ id = $appId; type = 'Microsoft.App/containerApps'; name = 'ca-fixture' }) -Depth 4 | Set-Content -LiteralPath $resourcesPath
        # A separate pwsh process running a script file, like Hibernate-ArcDemo.ps1: the in-process runner hides how -WhatIf
        # reaches the module's functions. The module's Invoke-DemoAz is replaced first, so this never calls the Azure CLI.
        $caller = Join-Path $TestDrive 'whatif-caller.ps1'
        Set-Content -LiteralPath $caller -Value @(
            '[CmdletBinding(SupportsShouldProcess)] param([string]$ModulePath, [string]$ResourcesPath)'
            'Import-Module $ModulePath -Force'
            '$module = Get-Module Common'
            '& $module { param($path) $script:DemoSubscription = "11111111-1111-1111-1111-111111111111"; $script:FixturePath = $path; function script:Invoke-DemoAz { param([string[]]$Arguments) if ($Arguments[0] -eq "resource") { Get-Content -Raw -LiteralPath $script:FixturePath } else { "[]" } } } $ResourcesPath'
            'if ((& $module { (Get-Command Invoke-DemoAz).ScriptBlock.ToString() }) -notmatch "FixturePath") { throw "The test double for Invoke-DemoAz is not in place." }'
            '$inventory = Get-DemoInventory "fixture" -ForHibernation'
            'ConvertTo-Json -Compress -InputObject @{ aks = @($inventory.AksClusterIds); apps = @($inventory.ContainerAppIds) }')
        $pwsh = (Get-Process -Id $PID).Path
        $output = @(& $pwsh -NoProfile -NonInteractive -File $caller -ModulePath (Join-Path $repo 'scripts\lib\Common.psm1') -ResourcesPath $resourcesPath -WhatIf 2>&1)
        $found = $output[-1] | ConvertFrom-Json
        @($found.aks) | Should -Be @($aksId) -Because ($output -join "`n")
        @($found.apps) | Should -Be @($appId) -Because ($output -join "`n")
    }

    It 'no script or module uses ForEach-Object with a bare member name' {
        $parser = [System.Management.Automation.Language.Parser]
        $offenders = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -Recurse -Include '*.ps1', '*.psm1') {
            $ast = $parser::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('ForEach-Object', '%') }, $true)
            foreach ($command in $commands) {
                $elements = @($command.CommandElements | Select-Object -Skip 1)
                $bare = @($elements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] })
                $named = @($elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'MemberName' })
                if ($bare.Count -or $named.Count) { "$($file.Name):$($command.Extent.StartLineNumber)" }
            }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'use ForEach-Object { $_.Member } so a -WhatIf preview still returns the values'
    }
}

Describe 'Job wait lines' {
    BeforeEach {
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Step { $script:lines.Add([string]$Message) } -ModuleName Common
    }

    It 'prints no wait line, and so no 15-minute budget, for jobs that have already finished' {
        $job = Start-Job -Name 'vm-fixture-done' -ScriptBlock { 'ok' }
        $job | Wait-Job | Out-Null
        Receive-DemoJobs -Jobs @($job) -TimeoutSeconds 900 -PassThru | Should -Be 'ok'
        @($script:lines | Where-Object { $_ -like 'Waiting for guest/extension jobs*' }) | Should -HaveCount 0
    }

    It 'names only the jobs that are still running' {
        $quick = Start-Job -Name 'vm-fixture-quick' -ScriptBlock { 'quick' }
        $slow = Start-Job -Name 'vm-fixture-slow' -ScriptBlock { Start-Sleep -Seconds 3; 'slow' }
        $quick | Wait-Job | Out-Null
        Receive-DemoJobs -Jobs @($quick, $slow) -TimeoutSeconds 60 -PassThru | Should -Be @('quick', 'slow')
        $script:lines.Count | Should -BeGreaterThan 0
        $script:lines[0] | Should -Match '^Waiting for guest/extension jobs: vm-fixture-slow \(\d+ s remaining\)$'
    }
}

Describe 'Hibernated container app readiness row' {
    It 'reports no active revision as an empty list, not as one null' {
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        Mock Get-DemoNetworkState -ModuleName Common {
            [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' }; ConflictMessage = '' }
        }
        Mock Invoke-DemoAz -ModuleName Common { '[{"name":"app--0000001","properties":{"active":false}}]' } -ParameterFilter { $Arguments[0] -eq 'containerapp' }
        $inventory = [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Machines = @(); AksClusterIds = @()
            ContainerAppIds = @("$script:root/Microsoft.App/containerApps/ca-fixture") }
        $row = @(Get-DemoReadinessChecks -Inventory $inventory -NamePrefix fixture -DesiredState Hibernated) | Where-Object id -eq 'containerapp/ca-fixture'
        $row.status | Should -Be 'pass'
        @($row.observed).Count | Should -Be 0
        (ConvertTo-Json -InputObject $row -Depth 4) | Should -Not -Match 'null'
    }

    It 'still lists the active revision names when one is active' {
        InModuleScope Common { $script:DemoSubscription = '11111111-1111-1111-1111-111111111111' }
        Mock Get-DemoNetworkState -ModuleName Common {
            [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' }; ConflictMessage = '' }
        }
        Mock Invoke-DemoAz -ModuleName Common { '[{"name":"app--0000002","properties":{"active":true}}]' } -ParameterFilter { $Arguments[0] -eq 'containerapp' }
        $inventory = [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Machines = @(); AksClusterIds = @()
            ContainerAppIds = @("$script:root/Microsoft.App/containerApps/ca-fixture") }
        $row = @(Get-DemoReadinessChecks -Inventory $inventory -NamePrefix fixture -DesiredState Hibernated) | Where-Object id -eq 'containerapp/ca-fixture'
        $row.status | Should -Be 'pending'
        @($row.observed) | Should -Be @('app--0000002')
    }
}
