BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
    $script:onboard = New-DemoArcLinuxOnboardScript -ServicePrincipalId 'sp-id' -ServicePrincipalSecret 'sp-secret' `
        -ResourceGroup 'rg-arc' -TenantId 'tenant-id' -Location 'australiaeast' -SubscriptionId 'sub-id' -Tags 'demo=arc'
}

Describe 'Linux Arc onboarding script' {
    It 'gives himdsd, extd and gcad MSFT_ARC_TEST through persistent systemd drop-ins' {
        $script:onboard | Should -Match 'for svc in himdsd extd gcad; do'
        $script:onboard | Should -Match 'service\.d/msft-arc-test\.conf'
        $script:onboard | Should -Match 'Environment=MSFT_ARC_TEST=true'
        $script:onboard | Should -Match 'systemctl set-environment MSFT_ARC_TEST=true'
    }

    It 'reloads systemd before connecting and restarts the daemons only afterwards' {
        $script:onboard | Should -Match '(?s)daemon-reload.*azcmagent connect.*systemctl restart extd gcad.*echo ARC_DEMO_OK\s*$'
    }

    It 'still connects with MSFT_ARC_TEST and the onboarding values' {
        $script:onboard | Should -Match 'sudo MSFT_ARC_TEST=true azcmagent connect'
        $script:onboard | Should -Match "--service-principal-id sp-id --service-principal-secret 'sp-secret'"
        $script:onboard | Should -Match '--resource-group rg-arc --tenant-id tenant-id --location australiaeast'
        $script:onboard | Should -Match '--subscription-id sub-id'
        $script:onboard | Should -Match '--tags "demo=arc"'
        $script:onboard | Should -Match '^set -e'
    }

    It 'does not let a failed daemon restart abort a successful onboarding' {
        $script:onboard | Should -Match 'systemctl restart extd gcad \|\| echo'
    }

    It 'uses LF line endings whatever the repo checkout uses' {
        $script:onboard | Should -Not -Match "`r"
    }

    It 'embeds the same drop-in step that fixes a host onboarded earlier' {
        $step = Get-DemoArcTestServiceEnvScript
        $step | Should -Not -Match 'azcmagent|apt-get'
        $script:onboard.Contains($step) | Should -BeTrue
    }

    It 'renders when nothing needs onboarding and there is no onboarding identity' {
        { New-DemoArcLinuxOnboardScript -ServicePrincipalId '' -ServicePrincipalSecret '' -ResourceGroup 'rg' `
                -TenantId 't' -Location 'l' -SubscriptionId 's' -Tags 'a=b' } | Should -Not -Throw
    }

    It 'is valid bash' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bash) {
            $probe = & $bash.Source -c 'echo ok' 2>$null
            if ($LASTEXITCODE -ne 0 -or $probe -ne 'ok') { $bash = $null }
        }
        if (-not $bash) { Set-ItResult -Skipped -Because 'a working bash is not available'; return }
        $script:onboard | & $bash.Source -n
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Deploy onboarding' {
    It 'builds the Linux script with the shared function' {
        $deploy = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'scripts\Deploy-ArcDemo.ps1') -Raw
        $deploy | Should -Match 'New-DemoArcLinuxOnboardScript'
        $deploy | Should -Not -Match 'sudo MSFT_ARC_TEST=true azcmagent connect'
    }
}
