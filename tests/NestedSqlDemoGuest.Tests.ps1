BeforeAll {
    $script:entry = Join-Path $PSScriptRoot '..\scripts\New-NestedSqlDemoGuest.ps1'
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        function Get-VM { param($Name, $Id) throw 'Unexpected Hyper-V call' }
        function Get-VMSwitch { param($Name) throw 'Unexpected switch call' }
        function New-VHD { param($Path) throw 'Unexpected disk creation' }
    }
    function Get-VMHardDiskDrive { param($VM) throw 'Unexpected disk read' }
    if (-not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        function Get-Volume { param($DriveLetter) throw 'Unexpected volume read' }
    }
}

Describe 'Simple scratch Windows guest preflight' {
    BeforeEach {
        $script:password = ConvertTo-SecureString 'Synthetic!Credential12345678901234567890' -AsPlainText -Force
        $script:arguments = @{
            VmName = 'DEMOSQL'
            VmRoot = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            WindowsIsoPath = (Join-Path $TestDrive 'approved.iso')
            SwitchName = 'DemoSwitch'
            AdministratorPassword = $script:password
        }
        New-Item -ItemType File -Path $script:arguments.WindowsIsoPath -Force | Out-Null
        Mock Get-VM { }
        Mock Get-VMSwitch { [pscustomobject]@{ Name = 'DemoSwitch' } }
        Mock Get-Volume { [pscustomobject]@{ SizeRemaining = 64GB } }
        Mock New-VHD { throw 'No preflight should create disks' }
    }
    AfterEach { $script:password.Dispose() }

    It 'rejects an existing guest without replacing it' {
        Mock Get-VM { [pscustomobject]@{ Name = 'DEMOSQL' } }
        { & $script:entry @script:arguments -Confirm:$false } | Should -Throw '*already exists*'
        Should -Invoke New-VHD -Times 0
    }

    It 'rejects an existing directory without overwriting it' {
        New-Item -ItemType Directory -Path $script:arguments.VmRoot | Out-Null
        { & $script:entry @script:arguments -Confirm:$false } | Should -Throw '*already exists*'
        Should -Invoke New-VHD -Times 0
    }

    It 'previews without creating a guest directory or VHD' {
        & $script:entry @script:arguments -WhatIf
        Test-Path -LiteralPath $script:arguments.VmRoot | Should -BeFalse
        Should -Invoke New-VHD -Times 0
    }

    It 'reuses only the explicitly supplied existing identity and disk paths' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $id = [guid]'11111111-2222-3333-4444-555555555555'
        $script:arguments.VmRoot = 'C:\Fixture\DEMOSQL'
        Mock Get-VM {
            [pscustomobject]@{Name='DEMOSQL';VMId=[guid]'11111111-2222-3333-4444-555555555555';State='Running';Path='C:\Fixture\DEMOSQL'}
        }
        Mock Get-VMHardDiskDrive {
            [pscustomobject]@{Path='C:\Fixture\DEMOSQL\DEMOSQL-OS.vhdx'}
            [pscustomobject]@{Path='C:\Fixture\DEMOSQL\DEMOSQL-SQLData.vhdx'}
        }
        $r = & $script:entry @script:arguments -ExistingVmId $id
        $r.Name | Should -Be DEMOSQL
        Should -Invoke New-VHD -Times 0
    }
}

Describe 'Scratch guest script output' {
    It 'discards the Dismount-DiskImage object so no raw CIM dump reaches the build output' {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:entry, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Dismount-DiskImage' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $pipeline = $call.Parent
            $pipeline | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
            $pipeline.PipelineElements[-1].GetCommandName() | Should -Be 'Out-Null'
        }
    }
}
