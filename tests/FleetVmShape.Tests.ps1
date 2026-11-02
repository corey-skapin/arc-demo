BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
    function New-FleetEntry {
        param([string]$Name = 'win-sql-02', [string]$OsType = 'Windows', [hashtable]$Extra = @{})
        $entry = [ordered]@{
            name = $Name; role = 'sql'; osType = $OsType; osTier = 'WS2019'
            imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2019-datacenter-gensecond'; imageVersion = 'latest'
            deploymentMode = 'azure-vm'; monitorTier = 'full-monitor'
            supportsAzureMonitor = $true; supportsVmInsights = $true; supportsChangeTracking = $true; supportsSql = $true; esuEligible = $false
        }
        foreach ($key in $Extra.Keys) { $entry[$key] = $Extra[$key] }
        [pscustomobject]$entry
    }
    $parentDisk = @{ name = 'nested-data'; lun = 0; sizeGb = 128; storageAccountType = 'StandardSSD_LRS'; caching = 'None' }
}

Describe 'Optional per-entry size, security type and data disks in the fleet schema' {
    It 'accepts a default entry with none of the new fields' {
        { Test-DemoFleet @(New-FleetEntry) } | Should -Not -Throw
    }
    It 'accepts a declared parent shape' {
        $entry = New-FleetEntry -Extra @{ vmSize = 'Standard_D4s_v5'; securityType = 'Standard'; dataDisks = @($parentDisk) }
        { Test-DemoFleet @($entry) } | Should -Not -Throw
    }
    It 'accepts an explicit empty disk list' {
        { Test-DemoFleet @(New-FleetEntry -Extra @{ dataDisks = @() }) } | Should -Not -Throw
    }
    It 'rejects an invalid <Case>' -TestCases @(
        @{ Case = 'size'; Extra = @{ vmSize = 'D4s_v5' }; Message = '*vmSize*' }
        @{ Case = 'security type'; Extra = @{ securityType = 'standard' }; Message = '*securityType*' }
        @{ Case = 'disk list type'; Extra = @{ dataDisks = 'disk' }; Message = '*dataDisks must be a JSON array*' }
        @{ Case = 'disk name'; Extra = @{ dataDisks = @(@{ name = 'Bad_Name'; lun = 0; sizeGb = 128 }) }; Message = '*names must be unique*' }
        @{ Case = 'duplicate disk name'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 0; sizeGb = 128 }, @{ name = 'a'; lun = 1; sizeGb = 128 }) }; Message = '*names must be unique*' }
        @{ Case = 'duplicate LUN'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 0; sizeGb = 128 }, @{ name = 'b'; lun = 0; sizeGb = 128 }) }; Message = '*lun*' }
        @{ Case = 'string LUN'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = '0'; sizeGb = 128 }) }; Message = '*lun*' }
        @{ Case = 'LUN range'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 64; sizeGb = 128 }) }; Message = '*lun*' }
        @{ Case = 'size range'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 0; sizeGb = 0 }) }; Message = '*sizeGb*' }
        @{ Case = 'disk tier'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 0; sizeGb = 128; storageAccountType = 'UltraSSD_LRS' }) }; Message = '*storageAccountType*' }
        @{ Case = 'caching'; Extra = @{ dataDisks = @(@{ name = 'a'; lun = 0; sizeGb = 128; caching = 'Always' }) }; Message = '*caching*' }
    ) {
        param($Case, $Extra, $Message)
        { Test-DemoFleet @(New-FleetEntry -Extra $Extra) } | Should -Throw $Message
    }
}

Describe 'Nested SQL parent shape from the skin' {
    It 'defaults to the proven nested-virtualization size and a 128 GiB disk' {
        $skin = @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'win-sql-02'; guestVmName = 'g'; arcMachineName = 'g' } }
        $config = Get-DemoNestedSqlGuestConfig -Skin $skin
        $config.ParentVmSize | Should -Be 'Standard_D4s_v5'
        $config.ParentDataDiskGb | Should -Be 128
        $config.ParentDataDiskStorageAccountType | Should -Be 'StandardSSD_LRS'
    }
    It 'honours explicit values and rejects invalid ones' {
        $skin = @{ nestedSqlGuest = @{ enabled = $true; parentVmName = 'p'; guestVmName = 'g'; arcMachineName = 'g'; parentVmSize = 'Standard_D8s_v5'; parentDataDiskGb = 256; parentDataDiskStorageAccountType = 'Standard_LRS' } }
        $config = Get-DemoNestedSqlGuestConfig -Skin $skin
        $config.ParentVmSize | Should -Be 'Standard_D8s_v5'
        $config.ParentDataDiskGb | Should -Be 256
        $config.ParentDataDiskStorageAccountType | Should -Be 'Standard_LRS'
        $skin.nestedSqlGuest.parentVmSize = 'D8s'
        { Get-DemoNestedSqlGuestConfig -Skin $skin } | Should -Throw '*parentVmSize*'
        $skin.nestedSqlGuest.parentVmSize = 'Standard_D8s_v5'
        $skin.nestedSqlGuest.parentDataDiskGb = 8
        { Get-DemoNestedSqlGuestConfig -Skin $skin } | Should -Throw '*parentDataDiskGb*'
        $skin.nestedSqlGuest.parentDataDiskGb = 256
        $skin.nestedSqlGuest.parentDataDiskStorageAccountType = 'UltraSSD_LRS'
        { Get-DemoNestedSqlGuestConfig -Skin $skin } | Should -Throw '*parentDataDiskStorageAccountType*'
    }
    It 'declares size, security type and disk on only the parent entry' {
        $config = [pscustomobject]@{ ParentVmName = 'win-sql-02'; ParentVmSize = 'Standard_D4s_v5'; ParentDataDiskGb = 128; ParentDataDiskStorageAccountType = 'StandardSSD_LRS' }
        $fleet = @(New-FleetEntry -Name 'win-sql-01'), (New-FleetEntry -Name 'win-sql-02')
        $result = @(Get-DemoFleetWithNestedParent -Fleet $fleet -NestedSqlGuest $config)
        $result.Count | Should -Be 2
        $result[0].PSObject.Properties.Name | Should -Not -Contain 'vmSize'
        $result[1].vmSize | Should -Be 'Standard_D4s_v5'
        $result[1].securityType | Should -Be 'Standard'
        @($result[1].dataDisks).Count | Should -Be 1
        $result[1].dataDisks[0].name | Should -Be 'nested-data'
        $result[1].dataDisks[0].sizeGb | Should -Be 128
        { Test-DemoFleet $result } | Should -Not -Throw
    }
    It 'keeps explicit fleet values and leaves the fleet alone without a nested guest' {
        $config = [pscustomobject]@{ ParentVmName = 'win-sql-02'; ParentVmSize = 'Standard_D4s_v5'; ParentDataDiskGb = 128; ParentDataDiskStorageAccountType = 'StandardSSD_LRS' }
        $explicit = New-FleetEntry -Extra @{ vmSize = 'Standard_D8s_v5'; dataDisks = @() }
        $result = @(Get-DemoFleetWithNestedParent -Fleet @($explicit) -NestedSqlGuest $config)
        $result[0].vmSize | Should -Be 'Standard_D8s_v5'
        @($result[0].dataDisks).Count | Should -Be 0
        $plain = New-FleetEntry
        @(Get-DemoFleetWithNestedParent -Fleet @($plain) -NestedSqlGuest $null)[0] | Should -Be $plain
    }
    It 'ignores a parent that is not a Windows fleet VM and handles hashtable entries' {
        $config = [pscustomobject]@{ ParentVmName = 'win-sql-02'; ParentVmSize = 'Standard_D4s_v5'; ParentDataDiskGb = 128; ParentDataDiskStorageAccountType = 'StandardSSD_LRS' }
        $linux = New-FleetEntry -OsType 'Linux'
        @(Get-DemoFleetWithNestedParent -Fleet @($linux) -NestedSqlGuest $config)[0].PSObject.Properties.Name | Should -Not -Contain 'vmSize'
        $table = @{ name = 'win-sql-02'; osType = 'Windows'; deploymentMode = 'azure-vm' }
        @(Get-DemoFleetWithNestedParent -Fleet @($table) -NestedSqlGuest $config)[0].vmSize | Should -Be 'Standard_D4s_v5'
    }
}

Describe 'Redeploy never silently resizes a VM or detaches a data disk' {
    BeforeAll {
        function New-ExistingVm {
            param([string]$Name = 'win-sql-02', [string]$Size = 'Standard_D4s_v5', [object[]]$Disks = @())
            [pscustomobject]@{ name = $Name; location = 'australiaeast'; hardwareProfile = [pscustomobject]@{ vmSize = $Size }
                storageProfile = [pscustomobject]@{ dataDisks = @($Disks) } }
        }
        function New-AttachedDisk {
            param([string]$Name = 'win-sql-02-nested-data', [int]$Lun = 0, [int]$SizeGb = 128, [string]$Type = 'StandardSSD_LRS')
            [pscustomobject]@{ name = $Name; lun = $Lun; diskSizeGb = $SizeGb; managedDisk = [pscustomobject]@{ storageAccountType = $Type } }
        }
        $declared = New-FleetEntry -Extra @{ vmSize = 'Standard_D4s_v5'; dataDisks = @($parentDisk) }
    }
    It 'passes when nothing exists yet or the declaration matches the retained VM' {
        { Assert-DemoRetainedVmShape -Machines @($declared) -ExistingVms @() -DefaultVmSize 'Standard_B2as_v2' } | Should -Not -Throw
        $existing = New-ExistingVm -Disks @(New-AttachedDisk)
        { Assert-DemoRetainedVmShape -Machines @($declared) -ExistingVms @($existing) -DefaultVmSize 'Standard_B2as_v2' } | Should -Not -Throw
    }
    It 'passes a default entry whose retained VM is the default size without disks' {
        $plain = New-FleetEntry -Name 'win-app-01'
        { Assert-DemoRetainedVmShape -Machines @($plain) -ExistingVms @(New-ExistingVm -Name 'win-app-01' -Size 'Standard_B2as_v2') -DefaultVmSize 'Standard_B2as_v2' } | Should -Not -Throw
    }
    It 'refuses to resize the retained parent back to the shared default' {
        $plain = New-FleetEntry
        { Assert-DemoRetainedVmShape -Machines @($plain) -ExistingVms @(New-ExistingVm) -DefaultVmSize 'Standard_B2as_v2' } | Should -Throw '*never resizes*'
    }
    It 'refuses to resize a retained VM to a newly declared size' {
        $existing = New-ExistingVm -Size 'Standard_B2as_v2'
        { Assert-DemoRetainedVmShape -Machines @($declared) -ExistingVms @($existing) -DefaultVmSize 'Standard_B2as_v2' } | Should -Throw '*Standard_B2as_v2 but*Standard_D4s_v5*'
    }
    It 'refuses an undeclared attached disk instead of detaching it' {
        $plainParent = New-FleetEntry -Extra @{ vmSize = 'Standard_D4s_v5' }
        $existing = New-ExistingVm -Disks @(New-AttachedDisk)
        { Assert-DemoRetainedVmShape -Machines @($plainParent) -ExistingVms @($existing) -DefaultVmSize 'Standard_B2as_v2' } | Should -Throw '*would be detached*'
    }
    It 'refuses to resize, convert or move a retained disk' -TestCases @(
        @{ SizeGb = 256; Type = 'StandardSSD_LRS'; Lun = 0 }
        @{ SizeGb = 128; Type = 'Premium_LRS'; Lun = 0 }
        @{ SizeGb = 128; Type = 'StandardSSD_LRS'; Lun = 3 }
    ) {
        param($SizeGb, $Type, $Lun)
        $disk = New-AttachedDisk -SizeGb $SizeGb -Type $Type -Lun $Lun
        { Assert-DemoRetainedVmShape -Machines @($declared) -ExistingVms @(New-ExistingVm -Disks @($disk)) -DefaultVmSize 'Standard_B2as_v2' } | Should -Throw '*differs from its declaration*'
    }
    It 'fails on an unreadable size rather than guessing' {
        $broken = [pscustomobject]@{ name = 'win-sql-02'; hardwareProfile = $null }
        { Assert-DemoRetainedVmShape -Machines @($declared) -ExistingVms @($broken) -DefaultVmSize 'Standard_B2as_v2' } | Should -Throw '*Cannot read the size*'
    }
}

Describe 'Capacity is demanded per distinct size' {
    BeforeAll {
        $parent = New-FleetEntry -Extra @{ vmSize = 'Standard_D4s_v5' }
        $others = @(New-FleetEntry -Name 'win-sql-01'), (New-FleetEntry -Name 'win-app-01')
    }
    It 'counts the parent separately from the shared size' {
        $demand = @(Get-DemoVmSizeDemand -Machines (@($others) + $parent) -ExistingVms @() -DefaultVmSize 'Standard_B2as_v2' -Location 'australiaeast')
        $demand.Count | Should -Be 2
        ($demand | Where-Object VmSize -eq 'Standard_B2as_v2').VmCount | Should -Be 2
        ($demand | Where-Object VmSize -eq 'Standard_D4s_v5').VmCount | Should -Be 1
    }
    It 'does not demand capacity for VMs that already exist at their declared size' {
        $existing = @(
            [pscustomobject]@{ name = 'win-sql-01'; location = 'australiaeast'; hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_B2as_v2' } }
            [pscustomobject]@{ name = 'win-sql-02'; location = 'australiaeast'; hardwareProfile = [pscustomobject]@{ vmSize = 'Standard_D4s_v5' } }
        )
        $demand = @(Get-DemoVmSizeDemand -Machines (@($others) + $parent) -ExistingVms $existing -DefaultVmSize 'Standard_B2as_v2' -Location 'australiaeast')
        ($demand | Where-Object VmSize -eq 'Standard_B2as_v2').VmCount | Should -Be 1
        ($demand | Where-Object VmSize -eq 'Standard_D4s_v5').VmCount | Should -Be 0
    }
    It 'always checks the shared default size, even for an empty fleet' {
        $demand = @(Get-DemoVmSizeDemand -Machines @() -ExistingVms @() -DefaultVmSize 'Standard_B2as_v2' -Location 'australiaeast')
        $demand.Count | Should -Be 1
        $demand[0].VmSize | Should -Be 'Standard_B2as_v2'
        $demand[0].VmCount | Should -Be 0
    }
}

Describe 'Deploy wiring for the declared nested parent' {
    BeforeAll {
        $fleetJson = @(
            (New-FleetEntry -Name 'win-sql-01'), (New-FleetEntry -Name 'win-sql-02')
        ) | ConvertTo-Json -Depth 6 -Compress
        $script:templateJson = '{"parameters":{"onPremFleet":{"defaultValue":' + $fleetJson + '}}}'
        $script:nestedSkin = Join-Path $TestDrive 'nested-skin.json'
        Set-Content -LiteralPath $script:nestedSkin -Value ('{"schemaVersion":1,"notifications":{"email":"test@example.com"},' +
            '"nestedSqlGuest":{"enabled":true,"parentVmName":"win-sql-02","guestVmName":"nested-guest","arcMachineName":"nested-guest"}}')
        $script:plainSkin = Join-Path $TestDrive 'plain-skin.json'
        Set-Content -LiteralPath $script:plainSkin -Value '{"schemaVersion":1,"notifications":{"email":"test@example.com"}}'
        function Invoke-FleetPreview {
            param([string]$SkinPath)
            & (Join-Path $repo 'scripts\Deploy-ArcDemo.ps1') -SubscriptionId '11111111-1111-1111-1111-111111111111' -TenantId '22222222-2222-2222-2222-222222222222' -SkinPath $SkinPath -WhatIf
        }
    }
    BeforeEach {
        Mock Import-Module {}
        Mock Test-Prerequisites { '33333333-3333-3333-3333-333333333333' }
        Mock Test-DemoComputeCapacity {}
        $global:FleetPreviewTemplate = $script:templateJson
        $global:FleetPreviewVms = '[]'
        Mock Invoke-DemoAz {
            param($Arguments)
            if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'list') { return $global:FleetPreviewVms }
            if ($Arguments[0] -eq 'bicep') { return $global:FleetPreviewTemplate }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].TrimStart('@')
                $global:FleetPreviewParameters = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                return 'preview'
            }
            if ($Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'list') { return '[]' }
            if ($Arguments[0] -in @('keyvault', 'network', 'consumption')) { return $null }
            if ($Arguments[0] -eq 'security' -and $Arguments[2] -eq 'show') { return '{"name":"VirtualMachines","pricingTier":"Free","subPlan":null,"extensions":null}' }
            throw "Unexpected preview operation: $($Arguments[0..1] -join ' ')"
        }
    }
    AfterEach {
        Remove-Variable FleetPreviewTemplate, FleetPreviewVms, FleetPreviewParameters -Scope Global -ErrorAction SilentlyContinue
    }
    It 'previews the parent with its size, security type and disk and checks each size' {
        Invoke-FleetPreview -SkinPath $script:nestedSkin
        $fleet = @($global:FleetPreviewParameters.parameters.onPremFleet.value)
        $parent = $fleet | Where-Object name -eq 'win-sql-02'
        $parent.vmSize | Should -Be 'Standard_D4s_v5'
        $parent.securityType | Should -Be 'Standard'
        @($parent.dataDisks).Count | Should -Be 1
        $parent.dataDisks[0].sizeGb | Should -Be 128
        ($fleet | Where-Object name -eq 'win-sql-01').PSObject.Properties.Name | Should -Not -Contain 'vmSize'
        Should -Invoke Test-DemoComputeCapacity -Times 1 -Exactly -ParameterFilter {
            @($Requirements).Count -eq 2 -and
            @($Requirements | Where-Object { $_.VmSize -eq 'Standard_B2as_v2' -and $_.VmCount -eq 1 }).Count -eq 1 -and
            @($Requirements | Where-Object { $_.VmSize -eq 'Standard_D4s_v5' -and $_.VmCount -eq 1 }).Count -eq 1
        }
    }
    It 'leaves a skin without a nested guest on the shared size and disks' {
        Invoke-FleetPreview -SkinPath $script:plainSkin
        $fleet = @($global:FleetPreviewParameters.parameters.onPremFleet.value)
        $fleet.PSObject.Properties.Name | Should -Not -Contain 'dataDisks'
        ($fleet | Where-Object name -eq 'win-sql-02').PSObject.Properties.Name | Should -Not -Contain 'vmSize'
        Should -Invoke Test-DemoComputeCapacity -Times 1 -Exactly
        Should -Invoke Test-DemoComputeCapacity -Times 1 -Exactly -ParameterFilter {
            @($Requirements).Count -eq 1 -and $Requirements[0].VmSize -eq 'Standard_B2as_v2' -and $Requirements[0].VmCount -eq 2
        }
    }
    It 'refuses a plain redeploy over the resized parent before any preview' {
        $global:FleetPreviewVms = '[{"name":"win-sql-02","location":"australiaeast","hardwareProfile":{"vmSize":"Standard_D4s_v5"},"storageProfile":{"osDisk":{"managedDisk":{"id":"/fixture/os"}},"dataDisks":[]}}]'
        Mock Invoke-DemoAz -ModuleName Common { 'StandardSSD_LRS' }
        { Invoke-FleetPreview -SkinPath $script:plainSkin } | Should -Throw '*never resizes*'
        Should -Invoke Invoke-DemoAz -Times 0 -ParameterFilter { $Arguments[0] -eq 'deployment' -and $Arguments[2] -eq 'what-if' }
    }
    It 'converges on a retained parent that already has the declared size and disk' {
        $global:FleetPreviewVms = '[{"name":"win-sql-02","location":"australiaeast","hardwareProfile":{"vmSize":"Standard_D4s_v5"},"storageProfile":{"osDisk":{"managedDisk":{"id":"/fixture/os"}},"dataDisks":[{"name":"win-sql-02-nested-data","lun":0,"diskSizeGb":128,"managedDisk":{"storageAccountType":"StandardSSD_LRS"}}]}}]'
        Mock Invoke-DemoAz -ModuleName Common { 'StandardSSD_LRS' }
        Invoke-FleetPreview -SkinPath $script:nestedSkin
        Should -Invoke Test-DemoComputeCapacity -Times 1 -Exactly -ParameterFilter {
            @($Requirements | Where-Object { $_.VmSize -eq 'Standard_D4s_v5' -and $_.VmCount -eq 0 }).Count -eq 1
        }
    }
}
