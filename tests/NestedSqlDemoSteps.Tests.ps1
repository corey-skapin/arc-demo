BeforeAll {
    $script:connect = Join-Path $PSScriptRoot '..\scripts\Connect-NestedSqlDemoGuest.ps1'
    $script:install = Join-Path $PSScriptRoot '..\scripts\Install-NestedSqlDemoEngine.ps1'
    $script:check = Join-Path $PSScriptRoot '..\scripts\Test-NestedSqlDemoGuest.ps1'
}

Describe 'Arc agent bracketed block list' {
    BeforeAll {
        $path = Join-Path $PSScriptRoot '..\scripts\Enable-NestedSqlDemoExtension.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $guest = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)[0].ScriptBlock
        $statements = $guest.EndBlock.Statements
        $start = ($statements | Where-Object { $_.Extent.Text -like '$block = & $agent*' } | Select-Object -First 1).Extent.StartOffset
        $script:blockCheck = [scriptblock]::Create(($statements | Where-Object { $_.Extent.StartOffset -ge $start } | ForEach-Object { $_.Extent.Text }) -join "`n")
        function Invoke-TestBlockAgent { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) }
    }
    BeforeEach {
        $script:blockData = '[Other/Extension, Microsoft.AzureData/WindowsAgent.SqlServer]'
        Mock Invoke-TestBlockAgent {
            $global:LASTEXITCODE = 0
            if ($Arguments[1] -eq 'set') { $script:blockData = '[Other/Extension]' }
            @{Data=$script:blockData} | ConvertTo-Json -Compress
        }
    }
    It 'removes only the SQL entry from the actual bracketed agent format' {
        $agent = 'Invoke-TestBlockAgent'
        $result = & $script:blockCheck
        $result[-1].Data | Should -Be '[Other/Extension]'
        Should -Invoke Invoke-TestBlockAgent -Times 1 -ParameterFilter {
            $Arguments[1] -eq 'set' -and $Arguments[3] -eq 'Microsoft.AzureData/WindowsAgent.SqlServer' -and $Arguments[4] -eq '--remove'
        }
    }
    It 'does not mutate an already unblocked list' {
        $script:blockData = '[]'
        $agent = 'Invoke-TestBlockAgent'
        & $script:blockCheck | Out-Null
        Should -Invoke Invoke-TestBlockAgent -Times 0 -ParameterFilter { $Arguments[1] -eq 'set' }
    }
    It 'reports a failed removal rather than continuing to install' {
        Mock Invoke-TestBlockAgent { $global:LASTEXITCODE = 1 } -ParameterFilter { $Arguments[1] -eq 'set' }
        $agent = 'Invoke-TestBlockAgent'
        { & $script:blockCheck } | Should -Throw '*SQL-only unblock failed*'
    }
}

Describe 'Simple nested demo step previews' {
    BeforeEach {
        $script:password = ConvertTo-SecureString 'Synthetic!Credential12345678901234567890' -AsPlainText -Force
        $script:credential = [pscredential]::new('Administrator',$script:password)
        Mock Invoke-Command { throw 'Preview must not enter the guest' }
        Mock Invoke-RestMethod { throw 'Preview must not request credentials' }
    }
    AfterEach { $script:password.Dispose() }

    It 'previews Arc onboarding without guest or vault operations' {
        & $script:connect -VmName DEMOSQL -GuestCredential $script:credential `
            -GuestAddress 172.31.240.20 -Gateway 172.31.240.1 -DnsServer 168.63.129.16 `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' `
            -TenantId '22222222-2222-2222-2222-222222222222' `
            -ResourceGroup rg-demo -Location australiaeast -ArcName DEMOSQL `
            -OnboardingApplicationId '33333333-3333-3333-3333-333333333333' `
            -SecretVersionUri 'https://example.vault.azure.net/secrets/arc-onboarding-client-secret/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
            -VaultPrivateAddress 10.1.0.4 -WhatIf
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'previews SQL installation without entering the guest' {
        $iso = Join-Path $TestDrive 'sql.iso'
        New-Item -ItemType File -Path $iso | Out-Null
        & $script:install -VmName DEMOSQL -GuestCredential $script:credential -SqlIsoPath $iso `
            -ExpectedArcResourceId '/subscriptions/SYNTHETIC/resourceGroups/rg-demo/providers/Microsoft.HybridCompute/machines/DEMOSQL' -WhatIf
        Should -Invoke Invoke-Command -Times 0
    }

    It 'checks only the supplied guest and Arc identity' {
        Mock Invoke-Command {
            [pscustomobject]@{ SetupComplete=$true; ArcConnected=$true; SqlRunning=$true; SqlExtensionInventoryVerified=$false }
        } -ParameterFilter {
            $VMName -ceq 'DEMOSQL' -and $ArgumentList[0] -ceq 'SYNTHETIC-ARC-ID' -and
                $ArgumentList[2] -is [bool] -and -not $ArgumentList[2] -and
                $ArgumentList[3] -is [bool] -and -not $ArgumentList[3]
        }
        $result = & $script:check -VmName DEMOSQL -GuestCredential $script:credential -ExpectedArcResourceId SYNTHETIC-ARC-ID
        $result.SetupComplete | Should -BeTrue
        $result.SqlExtensionInventoryVerified | Should -BeFalse
        Should -Invoke Invoke-Command -Times 1
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'passes real boolean switches to the guest rather than truthy cast strings' {
        Mock Invoke-Command { [pscustomobject]@{ Checked=$true } } -ParameterFilter {
            $ArgumentList[2] -is [bool] -and $ArgumentList[2] -and
                $ArgumentList[3] -is [bool] -and -not $ArgumentList[3]
        }
        $result = & $script:check -VmName DEMOSQL -GuestCredential $script:credential `
            -ExpectedArcResourceId SYNTHETIC-ARC-ID -RequireSqlExtension
        $result.Checked | Should -BeTrue
        Should -Invoke Invoke-Command -Times 1 -ParameterFilter {
            $ArgumentList[2] -is [bool] -and $ArgumentList[2] -and
                $ArgumentList[3] -is [bool] -and -not $ArgumentList[3]
        }
    }

    It 'surfaces failed guest access rather than reporting readiness' {
        Mock Invoke-Command { throw 'Guest authentication failed' }
        { & $script:check -VmName DEMOSQL -GuestCredential $script:credential -ExpectedArcResourceId SYNTHETIC-ARC-ID } |
            Should -Throw '*authentication failed*'
    }
}
