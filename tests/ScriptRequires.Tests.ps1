BeforeAll {
    $repo = Split-Path $PSScriptRoot
    # These run on the Hyper-V parent or inside the nested guest, in Windows PowerShell 5.1, never on your workstation.
    $script:GuestSideScripts = @(
        'Connect-NestedSqlDemoGuest.ps1'
        'Enable-NestedSqlDemoExtension.ps1'
        'Install-NestedSqlDemoEngine.ps1'
        'New-NestedSqlDemoGuest.ps1'
        'Remove-NestedSqlDemoGuest.ps1'
        'Test-NestedSqlDemoGuest.ps1'
        'Wait-NestedSqlDemoSetup.ps1'
    )
    $script:Required = @{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -Filter '*.ps1' -File) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $script:Required[$file.Name] = $ast.ScriptRequirements.RequiredPSVersion
    }
}

Describe 'Every top-level script says which PowerShell it needs' {
    It 'declares #Requires -Version 7.4 unless it is on the guest-side list' {
        $script:Required.Count | Should -BeGreaterThan 0
        $offenders = foreach ($name in ($script:Required.Keys | Sort-Object)) {
            if ($name -notin $script:GuestSideScripts -and $script:Required[$name] -ne [version]'7.4') { $name }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'Windows PowerShell 5.1 must stop at the version message, not at parse errors or a failure part way through; put the line below the help block, because above it PowerShell drops the comment-based help'
    }

    It 'lists only guest-side scripts that exist and declare #Requires -Version 5.1' {
        $offenders = foreach ($name in $script:GuestSideScripts) {
            if (-not $script:Required.ContainsKey($name) -or $script:Required[$name] -ne [version]'5.1') { $name }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'a script on this list runs on Windows PowerShell 5.1; any other script needs 7.4'
    }
}
