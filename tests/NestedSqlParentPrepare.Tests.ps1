BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    $script:repoRoot = $repo
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1')
    $hostScriptPath = Join-Path $repo 'scripts\guest\Initialize-NestedSqlParentHost.ps1'
    $script:prepare = Join-Path $repo 'scripts\Prepare-NestedSqlParent.ps1'

    # --- guest functions, extracted from the guest script so they run offline on any OS ---
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($hostScriptPath, [ref]$null, [ref]$errors)
    if ($errors) { throw 'The parent host script does not parse.' }
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    # Windows API stand-ins (defined only where the OS lacks them) so every call can be mocked.
    $stubs = @{
        'Get-Volume' = 'DriveLetter'; 'Get-Partition' = 'DriveLetter', 'DiskNumber'; 'Get-Disk' = 'Number'
        'Set-Disk' = 'Number', 'IsOffline', 'IsReadOnly'; 'Initialize-Disk' = 'Number', 'PartitionStyle'
        'New-Partition' = 'DiskNumber', 'UseMaximumSize', 'DriveLetter'
        'Format-Volume' = 'DriveLetter', 'FileSystem', 'NewFileSystemLabel', 'AllocationUnitSize'
        'Get-WindowsFeature' = 'Name'; 'Install-WindowsFeature' = 'Name', 'IncludeManagementTools'
        'Get-CimInstance' = 'ClassName', 'Filter'; 'Set-CimInstance' = 'InputObject', 'Property'
        'Get-VMHost' = ''; 'Get-VM' = ''; 'Get-VMSwitch' = 'Name'
        'New-VMSwitch' = 'Name', 'SwitchType'; 'Get-NetIPAddress' = 'InterfaceAlias', 'InterfaceIndex', 'AddressFamily'
        'New-NetIPAddress' = 'InterfaceIndex', 'IPAddress', 'PrefixLength', 'AddressFamily'
        'Get-NetNat' = ''; 'New-NetNat' = 'Name', 'InternalIPInterfaceAddressPrefix'; 'Get-NetAdapter' = 'Name'
        'Get-NetRoute' = 'AddressFamily'
    }
    foreach ($name in $stubs.Keys) {
        # Define a stub when the command is missing or its visible signature lacks what this file needs:
        # SqlEngine.Tests.ps1 leaves a Get-Volume stub without -DriveLetter behind in the same Pester run.
        $needed = @($stubs[$name] -split ',' | Where-Object { $_ })
        $visible = Get-Command $name -ErrorAction Ignore
        if ($visible -and -not @($needed | Where-Object { -not $visible.Parameters.ContainsKey($_) }).Count) { continue }
        $switchNames = 'UseMaximumSize', 'IncludeManagementTools'
        $parameters = @($needed | ForEach-Object { $(if ($_ -in $switchNames) { '[switch]$' } else { '$' }) + $_ }) -join ', '
        Set-Item "function:$name" -Value ([scriptblock]::Create("[CmdletBinding(SupportsShouldProcess)] param($parameters) throw 'Unmocked Windows API in offline tests.'"))
    }
    function New-TestDisk {
        param([int]$Number = 1, [int]$Lun = 0, [int64]$Size = 137438953472, [string]$Style = 'RAW', [bool]$Boot = $false)
        [pscustomobject]@{ Number = $Number; IsBoot = $Boot; IsSystem = $Boot; IsOffline = $false; IsReadOnly = $false
            Location = "Integrated : Adapter $([int](-not $Boot)) : Port 0 : Target 0 : LUN $Lun"; Size = $Size; PartitionStyle = $Style }
    }
    $script:settings = [pscustomobject]@{
        driveLetter = 'D'; label = 'NestedSQL'; root = (Join-Path $TestDrive 'NestedSQL'); lun = 0; sizeBytes = 137438953472
        switchName = 'NestedSqlSwitch'; natName = 'NestedSqlNat'; prefix = '172.31.240.0/24'; gateway = '172.31.240.1'
        azurePrefixes = @('10.50.0.0/16'); hashMedia = $true; media = @()
    }
}

Describe 'Parent host: IPv4 range helpers' {
    It 'computes the /24 and /16 ranges' {
        $range = ConvertTo-IPv4Range '172.31.240.0/24'
        ($range.End - $range.Start) | Should -Be 255
        $wide = ConvertTo-IPv4Range '10.50.0.0/16'
        ($wide.End - $wide.Start) | Should -Be 65535
    }
    It 'detects overlap in both directions and only real overlap' -TestCases @(
        @{ A = '172.31.240.0/24'; B = '10.50.0.0/16'; Expected = $false }
        @{ A = '172.31.240.0/24'; B = '172.31.0.0/16'; Expected = $true }
        @{ A = '172.31.0.0/16'; B = '172.31.240.0/24'; Expected = $true }
        @{ A = '172.31.240.0/24'; B = '172.31.240.77/32'; Expected = $true }
        @{ A = '172.31.240.0/24'; B = '172.31.241.0/24'; Expected = $false }
        @{ A = '172.31.240.0/24'; B = '168.63.129.16/32'; Expected = $false }
    ) {
        param($A, $B, $Expected)
        Test-IPv4Overlap (ConvertTo-IPv4Range $A) (ConvertTo-IPv4Range $B) | Should -Be $Expected
    }
}

Describe 'Parent host: data volume' {
    BeforeEach {
        New-Item -ItemType Directory -Path $script:settings.root -Force | Out-Null
        Mock Get-Volume {}
        Mock Get-Partition {}
        Mock Get-Disk { @((New-TestDisk -Number 0 -Boot $true), (New-TestDisk -Number 1)) }
        Mock Set-Disk {}
        Mock Initialize-Disk {}
        Mock New-Partition { [pscustomobject]@{ DriveLetter = 'D' } }
        Mock Format-Volume {}
    }
    AfterEach { Remove-Item -LiteralPath $script:settings.root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'initialises exactly the blank data disk at the Azure LUN as D: with the expected label and folders' {
        (Initialize-DataVolume $script:settings).changed | Should -BeTrue
        Should -Invoke Initialize-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 1 -and $PartitionStyle -eq 'GPT' }
        Should -Invoke New-Partition -Times 1 -Exactly -ParameterFilter { $DiskNumber -eq 1 -and $DriveLetter -eq 'D' -and $UseMaximumSize }
        Should -Invoke Format-Volume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'D' -and $FileSystem -eq 'NTFS' -and $NewFileSystemLabel -eq 'NestedSQL' -and $AllocationUnitSize -eq 65536 }
        Test-Path (Join-Path $script:settings.root 'VMs') | Should -BeTrue
        Test-Path (Join-Path $script:settings.root 'Media') | Should -BeTrue
    }
    It 'brings an offline or read-only data disk online first and tolerates an initialised GPT disk' {
        Mock Get-Disk { @([pscustomobject]@{ Number = 1; IsBoot = $false; IsSystem = $false; IsOffline = $true; IsReadOnly = $true; Location = 'Integrated : Adapter 1 : Port 0 : Target 0 : LUN 0'; Size = 137438953472; PartitionStyle = 'GPT' }) }
        Initialize-DataVolume $script:settings | Out-Null
        Should -Invoke Set-Disk -Times 2 -Exactly
        Should -Invoke Initialize-Disk -Times 0
        Should -Invoke New-Partition -Times 1 -Exactly
    }
    It 'does nothing but create missing folders when D: is already the labelled NTFS volume' {
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'NestedSQL'; Size = 100GB; SizeRemaining = 90GB } }
        $result = Initialize-DataVolume $script:settings
        $result.changed | Should -BeTrue
        Should -Invoke Format-Volume -Times 0
        Should -Invoke Initialize-Disk -Times 0
        (Initialize-DataVolume $script:settings).changed | Should -BeFalse
    }
    It 'stops rather than touch a D: that belongs to something else' -TestCases @(
        @{ Label = 'Temporary Storage'; FileSystem = 'NTFS' }
        @{ Label = 'NestedSQL'; FileSystem = 'ReFS' }
    ) {
        param($Label, $FileSystem)
        Mock Get-Volume { [pscustomobject]@{ FileSystem = $FileSystem; FileSystemLabel = $Label; Size = 100GB; SizeRemaining = 90GB } }.GetNewClosure()
        { Initialize-DataVolume $script:settings } | Should -Throw '*already used by another volume*'
        Should -Invoke Format-Volume -Times 0
    }
    It 'refuses zero or several candidate disks and any disk that is not blank' {
        Mock Get-Disk { @((New-TestDisk -Number 0 -Boot $true)) }
        { Initialize-DataVolume $script:settings } | Should -Throw '*exactly one data disk*found 0*'
        Mock Get-Disk { @((New-TestDisk -Number 1), (New-TestDisk -Number 2)) }
        { Initialize-DataVolume $script:settings } | Should -Throw '*found 2*'
        Mock Get-Disk { @((New-TestDisk -Number 1 -Size 1GB)) }
        { Initialize-DataVolume $script:settings } | Should -Throw '*found 0*'
        Mock Get-Disk { @((New-TestDisk -Number 1)) }
        Mock Get-Partition { @([pscustomobject]@{ Type = 'Basic' }) } -ParameterFilter { $DiskNumber -eq 1 }
        { Initialize-DataVolume $script:settings } | Should -Throw '*already has partitions*'
        Should -Invoke Format-Volume -Times 0
        Should -Invoke Initialize-Disk -Times 0
    }

    Context 'when a size without a temp disk leaves D: to the empty virtual DVD-ROM' {
        BeforeEach {
            # Mock bodies run in the caller's scope, so the shared state lives in a global.
            $global:DvdTest = @{ Moved = $false; Taken = @('C', 'D') }
            Mock Get-Volume {
                if ($global:DvdTest.Moved) { return }
                [pscustomobject]@{ DriveType = 'CD-ROM'; FileSystem = ''; FileSystemLabel = ''; Size = 0; SizeRemaining = 0 }
            }
            Mock Get-CimInstance { @([pscustomobject]@{ DriveLetter = 'D:'; DriveType = 5; Capacity = $null }) } -ParameterFilter { $Filter -like '*DriveType = 5*' }
            Mock Get-CimInstance { @($global:DvdTest.Taken | ForEach-Object { [pscustomobject]@{ DriveLetter = "${_}:" } }) } -ParameterFilter { -not $Filter }
            Mock Get-CimInstance { if ($global:DvdTest.Moved) { @() } else { @([pscustomobject]@{ DriveLetter = 'D:' }) } } -ParameterFilter { $Filter -eq "DriveLetter = 'D:'" }
            Mock Set-CimInstance { $global:DvdTest.Moved = $true } -RemoveParameterType InputObject
        }
        AfterEach { Remove-Variable DvdTest -Scope Global -ErrorAction SilentlyContinue }
        It 'reports an empty optical D: as not a data volume' {
            $state = Get-DataVolumeState $script:settings
            $state.present | Should -BeFalse
            $state.opticalDrive | Should -BeTrue
        }
        It 'moves the empty DVD-ROM to Z: and then initialises the data disk as D:' {
            $result = Initialize-DataVolume $script:settings
            $result.changed | Should -BeTrue
            $result.opticalDriveMovedTo | Should -Be 'Z'
            Should -Invoke Set-CimInstance -Times 1 -Exactly -ParameterFilter { $Property.DriveLetter -eq 'Z:' }
            Should -Invoke New-Partition -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'D' }
            Should -Invoke Format-Volume -Times 1 -Exactly
        }
        It 'takes the next spare letter when Z: is in use' {
            $global:DvdTest.Taken = @('C', 'D', 'Z')
            (Initialize-DataVolume $script:settings).opticalDriveMovedTo | Should -Be 'Y'
            Should -Invoke Set-CimInstance -Times 1 -Exactly -ParameterFilter { $Property.DriveLetter -eq 'Y:' }
        }
        It 'never touches a DVD-ROM that holds a disc' {
            Mock Get-Volume { [pscustomobject]@{ DriveType = 'CD-ROM'; FileSystem = 'UDF'; FileSystemLabel = 'SOMEDISC'; Size = 4GB; SizeRemaining = 0 } }
            { Initialize-DataVolume $script:settings } | Should -Throw '*already used by another volume*'
            Should -Invoke Set-CimInstance -Times 0
            Should -Invoke Format-Volume -Times 0
        }
        It 'stops when no spare letter is free or D: is not one empty optical drive' {
            $global:DvdTest.Taken = @('C', 'D', 'Z', 'Y', 'X', 'W')
            { Initialize-DataVolume $script:settings } | Should -Throw '*No spare drive letter*'
            Mock Get-CimInstance { @([pscustomobject]@{ DriveLetter = 'D:'; DriveType = 5; Capacity = 1GB }) } -ParameterFilter { $Filter -like '*DriveType = 5*' }
            { Initialize-DataVolume $script:settings } | Should -Throw '*not one empty optical drive*'
            Should -Invoke Set-CimInstance -Times 0
            Should -Invoke Format-Volume -Times 0
        }
        It 'fails when the letter is still taken after the move' {
            Mock Set-CimInstance {} -RemoveParameterType InputObject
            Should -Invoke Format-Volume -Times 0
        }
    }
}

Describe 'Parent host: Hyper-V role' {
    It 'does not reinstall an installed role and reports no restart' {
        Mock Get-WindowsFeature { [pscustomobject]@{ Installed = $true } }
        Mock Install-WindowsFeature { throw 'must not install' }
        $result = Install-HyperVRole
        $result.changed | Should -BeFalse
        $result.restartNeeded | Should -BeFalse
    }
    It 'installs the role with management tools and asks for a restart from outside' {
        Mock Get-WindowsFeature { [pscustomobject]@{ Installed = $false } }
        Mock Install-WindowsFeature { [pscustomobject]@{ Success = $true; RestartNeeded = 'Yes'; ExitCode = 'SuccessRestartRequired' } }
        $result = Install-HyperVRole
        $result.changed | Should -BeTrue
        $result.restartNeeded | Should -BeTrue
        Should -Invoke Install-WindowsFeature -Times 1 -Exactly -ParameterFilter { $Name -eq 'Hyper-V' -and $IncludeManagementTools }
    }
    It 'fails loudly when installation fails' {
        Mock Get-WindowsFeature { [pscustomobject]@{ Installed = $false } }
        Mock Install-WindowsFeature { [pscustomobject]@{ Success = $false; RestartNeeded = 'No'; ExitCode = 'Failed' } }
        { Install-HyperVRole } | Should -Throw '*installation failed*'
    }
    It 'never restarts the machine from the guest' {
        $text = Get-Content -LiteralPath $hostScriptPath -Raw
        $text | Should -Not -Match 'Restart-Computer|shutdown\.exe|Stop-Computer'
    }
}

Describe 'Parent host: switch and NAT' {
    BeforeEach {
        Mock New-VMSwitch {}
        Mock Get-VMSwitch {}
        Mock Get-NetAdapter { [pscustomobject]@{ ifIndex = 12 } }
        Mock Get-NetIPAddress {}
        Mock New-NetIPAddress {}
        Mock Get-NetNat {}
        Mock New-NetNat {}
        Mock Get-NetRoute { @([pscustomobject]@{ DestinationPrefix = '10.50.1.0/24'; InterfaceAlias = 'Ethernet 2' }, [pscustomobject]@{ DestinationPrefix = '168.63.129.16/32'; InterfaceAlias = 'Ethernet 2' }, [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; InterfaceAlias = 'Ethernet 2' }) }
        Mock Start-Sleep {}
    }
    It 'creates the internal switch, the host address and the NAT when none exist' {
        (Initialize-NestedNetwork $script:settings).changed | Should -BeTrue
        Should -Invoke New-VMSwitch -Times 1 -Exactly -ParameterFilter { $Name -eq 'NestedSqlSwitch' -and $SwitchType -eq 'Internal' }
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '172.31.240.1' -and $PrefixLength -eq 24 }
        Should -Invoke New-NetNat -Times 1 -Exactly -ParameterFilter { $Name -eq 'NestedSqlNat' -and $InternalIPInterfaceAddressPrefix -eq '172.31.240.0/24' }
    }
    It 'changes nothing when everything already matches' {
        Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
        Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '172.31.240.1'; PrefixLength = 24 }) }
        Mock Get-NetNat { @([pscustomobject]@{ Name = 'NestedSqlNat'; InternalIPInterfaceAddressPrefix = '172.31.240.0/24' }) }
        (Initialize-NestedNetwork $script:settings).changed | Should -BeFalse
        Should -Invoke New-VMSwitch -Times 0
        Should -Invoke New-NetIPAddress -Times 0
        Should -Invoke New-NetNat -Times 0
    }
    It 'refuses a guest prefix that overlaps Azure or an existing route' {
        $overlap = $script:settings.PSObject.Copy()
        $overlap.azurePrefixes = @('172.31.0.0/16')
        { Initialize-NestedNetwork $overlap } | Should -Throw '*overlaps the Azure address space*'
        Mock Get-NetRoute { @([pscustomobject]@{ DestinationPrefix = '172.31.240.0/25'; InterfaceAlias = 'Ethernet 3' }) }
        { Initialize-NestedNetwork $script:settings } | Should -Throw '*overlaps the existing route*'
        Should -Invoke New-VMSwitch -Times 0
    }
    It 'refuses conflicting NAT, switch type and host address configuration' {
        Mock Get-NetNat { @([pscustomobject]@{ Name = 'NestedSqlNat'; InternalIPInterfaceAddressPrefix = '192.168.0.0/24' }) }
        { Initialize-NestedNetwork $script:settings } | Should -Throw '*NAT conflicts*'
        Mock Get-NetNat { @([pscustomobject]@{ Name = 'OtherNat'; InternalIPInterfaceAddressPrefix = '172.31.240.0/24' }) }
        { Initialize-NestedNetwork $script:settings } | Should -Throw '*Another NAT*'
        Mock Get-NetNat {}
        Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'External' } }
        { Initialize-NestedNetwork $script:settings } | Should -Throw '*not Internal*'
        Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
        Mock Get-NetIPAddress { @([pscustomobject]@{ IPAddress = '172.31.240.9'; PrefixLength = 24 }) }
        { Initialize-NestedNetwork $script:settings } | Should -Throw '*conflicting IPv4*'
        Should -Invoke New-NetNat -Times 0
        Should -Invoke New-NetIPAddress -Times 0
    }
}

Describe 'Parent host script runs on Windows PowerShell 5.1' -Skip:(-not $IsWindows) {
    It 'parses without PowerShell 7 syntax' {
        $command = "`$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$hostScriptPath', [ref]`$null, [ref]`$e); if (`$e) { `$e | Out-String; exit 1 }"
        $output = & powershell.exe -NoProfile -NonInteractive -Command $command 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }
}

Describe 'Prepare-NestedSqlParent against a simulated parent' {
    BeforeAll {
        # Mock bodies run in the caller's scope, so shared state lives in a global world object.
        function global:Get-FakeVmJson {
            $w = $global:PrepWorld
            @{
                name = 'win-sql-02'; id = '/subscriptions/x/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines/win-sql-02'
                vmId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; location = 'australiaeast'; powerState = $w.Power; provisioningState = 'Succeeded'
                hardwareProfile = @{ vmSize = $w.Size }; securityProfile = @{ securityType = 'Standard' }
                tags = @{ owner = 'demo'; role = 'sql' }
                storageProfile = @{ dataDisks = @($w.Attached) }
            } | ConvertTo-Json -Depth 8 -Compress
        }
        function global:New-FakeWorld {
            param([string]$Size = 'Standard_B2as_v2', [bool]$Declared = $false, [bool]$Prepared = $false, [bool]$NatAttached = $true)
            $attached = @()
            if ($Declared -or $Prepared) { $attached = @(@{ name = 'win-sql-02-nested-data'; lun = 0; caching = 'None'; diskSizeGb = 128; managedDisk = @{ storageAccountType = 'StandardSSD_LRS' } }) }
            $mediaPresent = $Prepared
            @{
                Power = 'VM running'; Size = $(if ($Declared -or $Prepared) { 'Standard_D4s_v5' } else { $Size }); Attached = $attached; Disks = @{}
                Nat = $NatAttached; Calls = [System.Collections.Generic.List[string]]::new(); GuestRunningGuests = 0
                Volume = $Prepared; HyperVInstalled = $Prepared; HypervisorRunning = $Prepared; Network = $Prepared; Media = $mediaPresent
                ForeignD = $false; ResizeFails = $false; MediaHashOk = $true; RestartKeepsHypervisorOff = $false; OpticalDrive = $false
                Restarted = $false; InspectFailuresAfterRestart = 0
            }
        }
        $script:skin = Join-Path $TestDrive 'nested-skin.json'
        Set-Content -LiteralPath $script:skin -Value '{"schemaVersion":1,"azure":{"namePrefix":"fixture"},"nestedSqlGuest":{"enabled":true,"parentVmName":"win-sql-02","guestVmName":"nested-guest","arcMachineName":"nested-guest"}}'
        $script:common = @{
            SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = '22222222-2222-2222-2222-222222222222'; SkinPath = $script:skin
        }
        $script:wsHash = (Get-DemoMediaManifest | Where-Object Id -eq 'windows-server-2022-eval').Sha256
    }
    AfterAll {
        Remove-Item function:global:Get-FakeVmJson, function:global:New-FakeWorld -ErrorAction SilentlyContinue
        Remove-Variable PrepWorld -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $script:build = Join-Path $TestDrive ('build-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:record = Join-Path $TestDrive ('accept-' + [guid]::NewGuid().ToString('N') + '.json')
        $global:PrepWorld = New-FakeWorld
        Mock Import-Module {}
        Mock Start-Sleep {}
        Mock Initialize-DemoContext {}
        Mock Test-DemoComputeCapacity {}
        Mock Get-DemoNetworkState {
            $natId = '/fixture/nat'
            [pscustomobject]@{ NatId = $natId; Subnet = [pscustomobject]@{ natGateway = $(if ($global:PrepWorld.Nat) { [pscustomobject]@{ id = $natId } } else { $null }) } }
        }
        Mock Get-DemoGuestTarget {
            [pscustomobject]@{ Target = [pscustomobject]@{ Id = '/fixture/win-sql-02'; Name = 'win-sql-02'; OsType = 'Windows'; Native = $false
                Actual = ((Get-FakeVmJson) | ConvertFrom-Json) } }
        }
        Mock Invoke-DemoAz {
            $w = $global:PrepWorld
            $verb = "$($Arguments[0]) $($Arguments[1])"
            switch ($verb) {
                'vm show' { return Get-FakeVmJson }
                'vm deallocate' { $w.Calls.Add('vm deallocate'); $w.Power = 'VM deallocated'; return }
                'vm resize' {
                    if ($w.ResizeFails) { throw 'AllocationFailed: simulated capacity failure' }
                    $w.Calls.Add('vm resize ' + $Arguments[[Array]::IndexOf($Arguments, '--size') + 1]); $w.Size = $Arguments[[Array]::IndexOf($Arguments, '--size') + 1]; return
                }
                'vm start' { $w.Calls.Add('vm start'); $w.Power = 'VM running'; return }
                'vm restart' { $w.Calls.Add('vm restart'); $w.Restarted = $true; if ($w.HyperVInstalled -and -not $w.RestartKeepsHypervisorOff) { $w.HypervisorRunning = $true }; return }
                'disk show' {
                    $name = if ('--ids' -in $Arguments) { ($Arguments[[Array]::IndexOf($Arguments, '--ids') + 1] -split '/')[-1] } else { $Arguments[[Array]::IndexOf($Arguments, '-n') + 1] }
                    if (-not $w.Disks.ContainsKey($name)) { return $null }
                    return ($w.Disks[$name] | ConvertTo-Json -Compress)
                }
                'disk create' {
                    $name = $Arguments[[Array]::IndexOf($Arguments, '-n') + 1]
                    $w.Calls.Add("disk create $name")
                    $w.Disks[$name] = @{ name = $name; diskSizeGb = [int]$Arguments[[Array]::IndexOf($Arguments, '--size-gb') + 1]; sku = @{ name = $Arguments[[Array]::IndexOf($Arguments, '--sku') + 1] }; managedBy = $null }
                    return
                }
                'vm disk' {
                    $name = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                    $w.Calls.Add("disk attach $name")
                    $w.Attached = @(@{ name = $name; lun = [int]$Arguments[[Array]::IndexOf($Arguments, '--lun') + 1]; caching = $Arguments[[Array]::IndexOf($Arguments, '--caching') + 1]
                        diskSizeGb = $w.Disks[$name].diskSizeGb; managedDisk = @{ storageAccountType = $w.Disks[$name].sku.name } })
                    return
                }
                'connectedmachine show' { return '{"status":"Connected","provisioningState":"Succeeded"}' }
                'network vnet' { return '["10.50.0.0/16"]' }
                'ad sp' { return '["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]' }
                'account show' { return 'operator@example.com' }
                default { throw "Unexpected az call in the simulation: $verb" }
            }
        }
        Mock Invoke-DemoGuestAction {
            $w = $global:PrepWorld
            $w.Calls.Add("guest $Action")
            $media = @($Settings.media | ForEach-Object { @{ id = $_.id; path = "D:\NestedSQL\Media\$($_.fileName)"; present = $w.Media; bytes = $(if ($w.Media) { $_.bytes } else { 0 }); sha256Matches = $(if ($w.Media -and $Settings.hashMedia) { $w.MediaHashOk } else { $null }) } })
            switch ($Action) {
                'Inspect' {
                    if ($w.Restarted -and $w.InspectFailuresAfterRestart -gt 0) {
                        $w.InspectFailuresAfterRestart--
                        throw 'Guest action Inspect failed on win-sql-02: Cannot connect to CIM server. A system shutdown is in progress.'
                    }
                    return ([pscustomobject]@{
                        volume = @{ present = $w.Volume; fileSystem = 'NTFS'; label = 'NestedSQL'; sizeBytes = 137438953472; freeBytes = 130GB; lun = 0; vmsFolder = $w.Volume; mediaFolder = $w.Volume }
                        hyperV = @{ installed = $w.HyperVInstalled; vmms = $(if ($w.HypervisorRunning) { 'Running' } else { 'Stopped' }); hypervisorPresent = $w.HypervisorRunning; vmHostOk = $w.HypervisorRunning; runningGuests = $w.GuestRunningGuests }
                        network = @{ switchExists = $w.Network; switchType = $(if ($w.Network) { 'Internal' } else { '' }); addresses = $(if ($w.Network) { @('172.31.240.1/24') } else { @() }); nats = $(if ($w.Network) { @(@{ name = 'NestedSqlNat'; prefix = '172.31.240.0/24' }) } else { @() }) }
                        media = $media
                    } | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
                }
                'Volume' { if ($w.ForeignD) { throw 'Guest action Volume failed on win-sql-02: Drive D: is already used by another volume; refusing to change it.' }; $w.Volume = $true; return [pscustomobject]@{ changed = $true; opticalDriveMovedTo = $(if ($w.OpticalDrive) { 'Z' }) } }
                'HyperV' { $w.HyperVInstalled = $true; return [pscustomobject]@{ changed = $true; restartNeeded = $true } }
                'Network' { $w.Network = $true; return [pscustomobject]@{ changed = $true } }
                'Save' {
                    $state = if ($w.Media) { 'present' } else { 'downloaded' }
                    $w.Media = $true
                    return [pscustomobject]@{ items = @($Settings.items | ForEach-Object { [pscustomobject]@{ id = $_.id; path = "$($Settings.root)\$($_.fileName)"; bytes = $_.bytes; sha256 = $_.sha256; state = $state } }) }
                }
            }
        }
    }
    AfterEach { Remove-Variable PrepWorld -Scope Global -ErrorAction SilentlyContinue }

    It 'prepares an undeclared B-series parent end to end, in order, and emits the build input' {
        $result = & $script:prepare @script:common -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -BuildInputPath $script:build -AcceptanceRecordPath $script:record -Confirm:$false
        $result.status | Should -Be 'pass'
        ($result.phases | ForEach-Object { "$($_.phase):$($_.status)" }) -join ' ' | Should -Be 'Preflight:satisfied Size:changed Disk:changed Volume:changed HyperV:changed Network:changed Media:changed Verify:pass'
        $calls = $global:PrepWorld.Calls
        $calls | Where-Object { $_ -notlike 'guest Inspect' } | Should -Be @(
            'vm deallocate', 'vm resize Standard_D4s_v5', 'vm start', 'disk create win-sql-02-nested-data', 'disk attach win-sql-02-nested-data',
            'guest Volume', 'guest HyperV', 'vm restart', 'guest Network', 'guest Save')
        $input = Get-Content -LiteralPath $script:build -Raw | ConvertFrom-Json
        $input.ParentVmId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $input.WindowsIsoPath | Should -Be 'D:\NestedSQL\Media\Windows_Server_2022_Evaluation.iso'
        $input.SqlIsoPath | Should -Be 'D:\NestedSQL\Media\SQLServer2022-x64-ENU-Dev.iso'
        $input.SwitchName | Should -Be 'NestedSqlSwitch'
        $input.Gateway | Should -Be '172.31.240.1'
        $input.GuestAddress | Should -Be '172.31.240.20'
        $input.DnsServer | Should -Be '168.63.129.16'
        $input.Location | Should -Be 'australiaeast'
        $input.OnboardingApplicationId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $accepted = (Get-Command (Join-Path $script:repoRoot 'scripts\New-NestedSqlDemo.ps1')).Parameters.Keys
        @($input.PSObject.Properties.Name | Where-Object { $_ -notin $accepted }) | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $script:record -Raw | ConvertFrom-Json).items.'windows-server-2022-eval'.licenseUrl | Should -Match '^https://'
    }
    It 'a second run on the prepared parent changes nothing: no resize, restart or guest mutation' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $result = & $script:prepare @script:common -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -BuildInputPath $script:build -AcceptanceRecordPath $script:record -Confirm:$false
        $result.status | Should -Be 'pass'
        ($result.phases | ForEach-Object { "$($_.phase):$($_.status)" }) -join ' ' | Should -Be 'Preflight:satisfied Size:satisfied Disk:satisfied Volume:satisfied HyperV:satisfied Network:satisfied Media:satisfied Verify:pass'
        @($global:PrepWorld.Calls | Where-Object { $_ -notlike 'guest Inspect' -and $_ -ne 'guest Save' }) | Should -BeNullOrEmpty
    }
    It 'skips Size and Disk when Deploy already declared the parent' {
        $global:PrepWorld = New-FakeWorld -Declared $true
        $result = & $script:prepare @script:common -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms -BuildInputPath $script:build -AcceptanceRecordPath $script:record -Confirm:$false
        $result.status | Should -Be 'pass'
        @($global:PrepWorld.Calls | Where-Object { $_ -match '^(vm resize|vm deallocate|disk )' }) | Should -BeNullOrEmpty
        @($global:PrepWorld.Calls | Where-Object { $_ -eq 'vm restart' }).Count | Should -Be 1
    }
    It 'previews with Azure reads only: no mutation, no guest command, no build input' {
        $result = & $script:prepare @script:common -WhatIf
        $global:PrepWorld.Calls | Should -BeNullOrEmpty
        Should -Invoke Invoke-DemoGuestAction -Times 0
        Test-Path $script:build | Should -BeFalse
        $result.status | Should -Be 'pending'
        ($result.phases | Where-Object phase -ne 'Preflight' | Where-Object status -ne 'skipped' | ForEach-Object phase) | Should -Not -Contain 'Size'
    }
    It 'reboots only from Azure and installs no role when the hypervisor merely needs a restart' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.HypervisorRunning = $false
        $result = & $script:prepare @script:common -Phase HyperV -Confirm:$false
        ($result.phases | Where-Object phase -eq 'HyperV').status | Should -Be 'changed'
        @($global:PrepWorld.Calls | Where-Object { $_ -eq 'guest HyperV' }) | Should -BeNullOrEmpty
        @($global:PrepWorld.Calls | Where-Object { $_ -eq 'vm restart' }).Count | Should -Be 1
    }
    It 'fails when Hyper-V is still not running after the restart' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.HyperVInstalled = $false
        $global:PrepWorld.HypervisorRunning = $false
        $global:PrepWorld.RestartKeepsHypervisorOff = $true
        { & $script:prepare @script:common -Phase HyperV -Confirm:$false } | Should -Throw '*not running after the restart*'
    }
    It 'inspects twice, a minute apart, after the restart before it calls Hyper-V ready' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.HypervisorRunning = $false
        $result = & $script:prepare @script:common -Phase HyperV -Confirm:$false
        ($result.phases | Where-Object phase -eq 'HyperV').status | Should -Be 'changed'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
        $calls = @($global:PrepWorld.Calls)
        @($calls[($calls.IndexOf('vm restart') + 1)..($calls.Count - 1)] | Where-Object { $_ -eq 'guest Inspect' }).Count | Should -BeGreaterOrEqual 2
    }
    It 'rides out the second restart that Windows makes on its own after the first boot' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.HypervisorRunning = $false
        $global:PrepWorld.InspectFailuresAfterRestart = 2
        $result = & $script:prepare @script:common -Phase HyperV -Confirm:$false
        ($result.phases | Where-Object phase -eq 'HyperV').status | Should -Be 'changed'
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
    }
    It 'surfaces the guest''s own error when it never answers after the restart' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.HypervisorRunning = $false
        $global:PrepWorld.InspectFailuresAfterRestart = 1000
        { & $script:prepare @script:common -Phase HyperV -Confirm:$false } | Should -Throw '*Cannot connect to CIM server. A system shutdown is in progress.*'
        Should -Invoke Start-Sleep -Times 20 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }
    It 'refuses without both terms switches before any mutation' {
        { & $script:prepare @script:common -AcceptSqlDeveloperTerms -Confirm:$false } | Should -Throw '*AcceptWindowsEvaluationTerms*'
        $global:PrepWorld.Calls | Should -BeNullOrEmpty
    }
    It 'refuses an inactive lab, an untested size and a skin without the nested guest' {
        $global:PrepWorld.Nat = $false
        { & $script:prepare @script:common -Phase Volume -Confirm:$false } | Should -Throw '*not Active*'
        $global:PrepWorld.Calls | Should -BeNullOrEmpty
        $untested = Join-Path $TestDrive 'untested.json'
        Set-Content -LiteralPath $untested -Value '{"schemaVersion":1,"nestedSqlGuest":{"enabled":true,"parentVmName":"win-sql-02","guestVmName":"g","arcMachineName":"g","parentVmSize":"Standard_D8s_v5"}}'
        { & $script:prepare @script:common -SkinPath $untested -Phase Size -Confirm:$false } | Should -Throw '*AllowUntestedSize*'
        $plain = Join-Path $TestDrive 'plain.json'
        Set-Content -LiteralPath $plain -Value '{"schemaVersion":1}'
        { & $script:prepare @script:common -SkinPath $plain -Phase Verify } | Should -Throw '*Enable nestedSqlGuest*'
    }
    It 'stops at a failed resize with guidance and tries nothing else' {
        $global:PrepWorld.ResizeFails = $true
        { & $script:prepare @script:common -Phase Size -Confirm:$false } | Should -Throw '*stays deallocated*No other size or region*'
        $global:PrepWorld.Calls | Where-Object { $_ -ne 'guest Inspect' } | Should -Be @('vm deallocate')
    }
    It 'refuses to resize while a nested guest is running' {
        $global:PrepWorld.GuestRunningGuests = 1
        { & $script:prepare @script:common -Phase Size -Confirm:$false } | Should -Throw '*guest is running*'
        @($global:PrepWorld.Calls | Where-Object { $_ -like 'vm *' }) | Should -BeNullOrEmpty
    }
    It 'surfaces a foreign D: from the guest and runs no later phase' {
        $global:PrepWorld = New-FakeWorld -Declared $true
        $global:PrepWorld.ForeignD = $true
        { & $script:prepare @script:common -Confirm:$false -AcceptWindowsEvaluationTerms -AcceptSqlDeveloperTerms } | Should -Throw '*already used by another volume*'
        @($global:PrepWorld.Calls | Where-Object { $_ -in @('guest HyperV', 'guest Network', 'guest Save', 'vm restart') }) | Should -BeNullOrEmpty
    }
    It 'reports the empty virtual DVD-ROM that the guest moved off D:' {
        $global:PrepWorld = New-FakeWorld -Declared $true
        $global:PrepWorld.Volume = $false
        $global:PrepWorld.OpticalDrive = $true
        $result = & $script:prepare @script:common -Phase Volume -Confirm:$false
        $volume = $result.phases | Where-Object phase -eq 'Volume'
        $volume.status | Should -Be 'changed'
        $volume.detail | Should -BeLike '*DVD-ROM moved to Z:*'
    }
    It 'refuses LUN 0 held by another disk and a retained disk that differs from its declaration' {
        $global:PrepWorld = New-FakeWorld -Declared $true
        $global:PrepWorld.Attached = @(@{ name = 'someone-elses-disk'; lun = 0; caching = 'None'; diskSizeGb = 64; managedDisk = @{ storageAccountType = 'Standard_LRS' } })
        { & $script:prepare @script:common -Phase Disk -Confirm:$false } | Should -Throw '*LUN 0 already holds*'
        $global:PrepWorld.Attached = @(@{ name = 'win-sql-02-nested-data'; lun = 0; caching = 'None'; diskSizeGb = 256; managedDisk = @{ storageAccountType = 'StandardSSD_LRS' } })
        { & $script:prepare @script:common -Phase Disk -Confirm:$false } | Should -Throw '*never resizes, converts or moves*'
        @($global:PrepWorld.Calls | Where-Object { $_ -like 'disk *' }) | Should -BeNullOrEmpty
    }
    It 'judges a deallocated parent''s data disk by the disk resource, because its VM model reports no size or tier' {
        $global:PrepWorld = New-FakeWorld -Declared $true
        $global:PrepWorld.Power = 'VM deallocated'
        $global:PrepWorld.Attached = @(@{ name = 'win-sql-02-nested-data'; lun = 0; caching = 'None'; managedDisk = @{ id = '/fixture/disks/win-sql-02-nested-data' } })
        $global:PrepWorld.Disks['win-sql-02-nested-data'] = @{ name = 'win-sql-02-nested-data'; diskSizeGb = 128; sku = @{ name = 'StandardSSD_LRS' }; managedBy = '/fixture/win-sql-02' }
        $result = & $script:prepare @script:common -Phase Disk -Confirm:$false
        ($result.phases | Where-Object phase -eq 'Disk').status | Should -Be 'satisfied'
        @($global:PrepWorld.Calls | Where-Object { $_ -like 'disk *' -or $_ -like 'vm *' }) | Should -BeNullOrEmpty
        $global:PrepWorld.Disks['win-sql-02-nested-data'].sku.name = 'Standard_LRS'
        { & $script:prepare @script:common -Phase Disk -Confirm:$false } | Should -Throw '*never resizes, converts or moves*'
        @($global:PrepWorld.Calls | Where-Object { $_ -like 'disk *' -or $_ -like 'vm *' }) | Should -BeNullOrEmpty
    }
    It 'Verify never starts a parked parent and reports a failing check instead of a build input' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.Power = 'VM deallocated'
        { & $script:prepare @script:common -Phase Verify -BuildInputPath $script:build } | Should -Throw '*Verify failed*power*'
        @($global:PrepWorld.Calls | Where-Object { $_ -like 'vm *' }) | Should -BeNullOrEmpty
        Test-Path $script:build | Should -BeFalse
    }
    It 'Verify fails on a media hash mismatch and keeps existing build-input keys on success' {
        $global:PrepWorld = New-FakeWorld -Prepared $true
        $global:PrepWorld.MediaHashOk = $false
        { & $script:prepare @script:common -Phase Verify -BuildInputPath $script:build } | Should -Throw '*media/windows-server-2022-eval*'
        Test-Path $script:build | Should -BeFalse
        $global:PrepWorld.MediaHashOk = $true
        Set-Content -LiteralPath $script:build -Value '{"OperatorNote":"keep me","Gateway":"stale"}'
        $result = & $script:prepare @script:common -Phase Verify -BuildInputPath $script:build
        $result.status | Should -Be 'pass'
        ($result.phases | Where-Object phase -eq 'Preflight').detail | Should -BeLike '*lab Active: not checked*'
        $merged = Get-Content -LiteralPath $script:build -Raw | ConvertFrom-Json
        $merged.OperatorNote | Should -Be 'keep me'
        $merged.Gateway | Should -Be '172.31.240.1'
        @($global:PrepWorld.Calls | Where-Object { $_ -ne 'guest Inspect' }) | Should -BeNullOrEmpty
    }
}
