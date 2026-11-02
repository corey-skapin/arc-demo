BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\lib\Common.psm1')
}
BeforeAll {
    $repo = Split-Path $PSScriptRoot
    Import-Module (Join-Path $repo 'scripts\lib\Common.psm1') -Force
}

Describe 'UTC normalisation' {
    InModuleScope Common {
        It 'returns UTC for <Name>' -ForEach @(
            @{ Name = 'a Z string'; Value = '2030-01-01T10:00:00Z' }
            @{ Name = 'an offset string'; Value = '2030-01-01T20:30:00+10:30' }
            @{ Name = 'a Utc DateTime'; Value = [datetime]::new(2030, 1, 1, 10, 0, 0, [DateTimeKind]::Utc) }
            @{ Name = 'an Unspecified DateTime'; Value = [datetime]::new(2030, 1, 1, 10, 0, 0, [DateTimeKind]::Unspecified) }
            @{ Name = 'a DateTimeOffset'; Value = [DateTimeOffset]::new(2030, 1, 1, 20, 30, 0, [TimeSpan]::FromMinutes(630)) }
        ) {
            $utc = ConvertTo-DemoUtc $Value
            $utc.Kind | Should -Be 'Utc'
            $utc | Should -Be ([datetime]::new(2030, 1, 1, 10, 0, 0, [DateTimeKind]::Utc))
        }
        It 'returns null for an absent value' {
            ConvertTo-DemoUtc $null | Should -BeNullOrEmpty
            ConvertTo-DemoUtc '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Heartbeat times from one Log Analytics query' {
    InModuleScope Common {
        It 'asks for the latest Heartbeat per lower-cased resource and returns UTC times' {
            Mock Invoke-RestMethod {
                $script:fxBody = $Body
                '{"tables":[{"rows":[["/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/a","2030-01-01T00:05:00.5000000Z"],["/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/b","2030-01-01T00:07:00Z"]]}]}' | ConvertFrom-Json
            }
            $times = Get-DemoHeartbeatTimes -WorkspaceCustomerId 'workspace-id' -Token 'token'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.loganalytics.io/v1/workspaces/workspace-id/query' -and $Method -eq 'Post' }
            $query = ($script:fxBody | ConvertFrom-Json).query
            $query | Should -Match 'Heartbeat'
            $query | Should -Match 'summarize LastHeartbeat = max\(TimeGenerated\) by ResourceId = tolower\(_ResourceId\)'
            $times.Count | Should -Be 2
            $times['/subscriptions/s/resourcegroups/rg/providers/microsoft.hybridcompute/machines/a'].Kind | Should -Be 'Utc'
            $times['/SUBSCRIPTIONS/S/RESOURCEGROUPS/RG/providers/microsoft.hybridcompute/machines/b'] |
                Should -Be ([datetime]::new(2030, 1, 1, 0, 7, 0, [DateTimeKind]::Utc))
        }
        It 'surfaces a query error instead of reporting no Heartbeats' {
            Mock Invoke-RestMethod { '{"error":{"code":"PathNotFoundError"}}' | ConvertFrom-Json }
            { Get-DemoHeartbeatTimes -WorkspaceCustomerId 'workspace-id' -Token 'token' } | Should -Throw '*PathNotFoundError*'
        }
        It 'returns an empty table when nothing has reported' {
            Mock Invoke-RestMethod { '{"tables":[{"rows":[]}]}' | ConvertFrom-Json }
            (Get-DemoHeartbeatTimes -WorkspaceCustomerId 'workspace-id' -Token 'token').Count | Should -Be 0
        }
    }
}

Describe 'Time-boxed parallel ARM reads' {
    InModuleScope Common {
        It 'returns read failures instead of throwing' {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            $listener.Stop()
            $responses = @(Invoke-DemoArmGetParallel -Uri @("http://127.0.0.1:$port/a", "http://127.0.0.1:$port/b") -Token 'token' -TimeoutSeconds 20)
            $responses.Count | Should -Be 2
            @($responses | Where-Object { $_.Error -and -not $_.Body }).Count | Should -Be 2
            ($responses.Error -join ' ') | Should -Not -Match 'token'
        }
        It 'does nothing for an empty request' {
            @(Invoke-DemoArmGetParallel -Uri @() -Token 'token').Count | Should -Be 0
        }
    }
}

Describe 'Soft ARM states per host' {
    InModuleScope Common {
        BeforeEach {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $infra = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
            $arc = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines'
            $script:fxMachines = @(
                [pscustomobject]@{ Name = 'lnx-app-01'; Id = "$infra/lnx-app-01"; ArcId = "$arc/lnx-app-01"; OsType = 'Linux'; Monitor = $true; Native = $false }
                [pscustomobject]@{ Name = 'win-app-01'; Id = "$infra/win-app-01"; ArcId = "$arc/win-app-01"; OsType = 'Windows'; Monitor = $true; Native = $false }
                [pscustomobject]@{ Name = 'win-native'; Id = "$infra/win-native"; ArcId = $null; OsType = 'Windows'; Monitor = $true; Native = $true }
                [pscustomobject]@{ Name = 'win-parent'; Id = "$infra/win-parent"; ArcId = $null; OsType = 'Windows'; Monitor = $false; Native = $true }
            )
            $script:fxUris = $null
            Mock Invoke-DemoArmGetParallel {
                $script:fxUris = @($Uri)
                foreach ($u in $Uri) {
                    if ($u -match '/lnx-app-01/extensions\?') {
                        [pscustomobject]@{ Uri = $u; Error = $null; Body = [pscustomobject]@{ value = @(
                            [pscustomobject]@{ name = 'AzureMonitorLinuxAgent'; properties = [pscustomobject]@{ provisioningState = 'Updating' } }
                            [pscustomobject]@{ name = 'MDE.Linux'; properties = [pscustomobject]@{ provisioningState = 'Succeeded' } }) } }
                    } elseif ($u -match '/win-app-01/extensions\?') {
                        [pscustomobject]@{ Uri = $u; Error = $null; Body = [pscustomobject]@{ value = @(
                            [pscustomobject]@{ name = 'AzureMonitorWindowsAgent'; properties = [pscustomobject]@{ provisioningState = 'Failed' } }) } }
                    } elseif ($u -match '/win-native/extensions\?') {
                        [pscustomobject]@{ Uri = $u; Error = 'Forbidden'; Body = $null }
                    } elseif ($u -match '/lnx-app-01/instanceView\?') {
                        [pscustomobject]@{ Uri = $u; Error = $null; Body = [pscustomobject]@{
                            statuses = @([pscustomobject]@{ code = 'ProvisioningState/updating'; displayStatus = 'Updating' }, [pscustomobject]@{ code = 'PowerState/running'; displayStatus = 'VM running' })
                            vmAgent = [pscustomobject]@{ statuses = @([pscustomobject]@{ displayStatus = 'Ready' }) }
                            extensions = @(
                                [pscustomobject]@{ name = 'MDE.Linux'; statuses = @([pscustomobject]@{ displayStatus = 'Transitioning' }) }
                                [pscustomobject]@{ name = 'AzureMonitorLinuxAgent'; statuses = @([pscustomobject]@{ displayStatus = 'Provisioning succeeded' }) }) } }
                    }
                }
            }
        }
        It 'reads Linux and native extensions through the VM and Windows Arc extensions through Arc' {
            $states = Get-DemoHostArmStates -Machines $script:fxMachines -Token 'token'
            @($script:fxUris | Where-Object { $_ -match 'Microsoft.Compute/virtualMachines/lnx-app-01/extensions\?api-version=2024-07-01$' }).Count | Should -Be 1
            @($script:fxUris | Where-Object { $_ -match 'Microsoft.HybridCompute/machines/win-app-01/extensions\?api-version=2024-07-10$' }).Count | Should -Be 1
            @($script:fxUris | Where-Object { $_ -match 'Microsoft.Compute/virtualMachines/win-native/extensions\?' }).Count | Should -Be 1
            $script:fxUris.Count | Should -Be 3
            $states.Extensions['lnx-app-01']['AzureMonitorLinuxAgent'] | Should -Be 'Updating'
            $states.Extensions['lnx-app-01']['MDE.Linux'] | Should -Be 'Succeeded'
            $states.Extensions['win-app-01']['AzureMonitorWindowsAgent'] | Should -Be 'Failed'
        }
        It 'keeps a failed read soft and attributes it to the host' {
            $states = Get-DemoHostArmStates -Machines $script:fxMachines -Token 'token'
            $states.Errors['win-native/extensions'] | Should -Be 'Forbidden'
            $states.Extensions.ContainsKey('win-native') | Should -BeFalse
        }
        It 'reads VM power, agent and in-flight extension state only for the named hosts' {
            $states = Get-DemoHostArmStates -Machines $script:fxMachines -Token 'token' -VmStateFor @('lnx-app-01', 'win-parent')
            @($script:fxUris | Where-Object { $_ -match '/instanceView\?api-version=2024-07-01$' }).Count | Should -Be 2
            $vm = $states.Vm['lnx-app-01']
            $vm.Power | Should -Be 'VM running'
            $vm.AgentReady | Should -BeTrue
            $vm.Updating | Should -BeTrue
            $vm.TransitioningExtensions | Should -Be @('MDE.Linux')
            $states.Errors['win-parent/vm'] | Should -Match 'did not finish'
        }
        It 'makes no ARM call when nothing needs reading' {
            $states = Get-DemoHostArmStates -Machines @($script:fxMachines | Where-Object Name -eq 'win-parent') -Token 'token'
            Should -Invoke Invoke-DemoArmGetParallel -Times 0
            $states.Extensions.Count | Should -Be 0
        }
    }
}

Describe 'Opt-in guest check script' {
    InModuleScope Common {
        BeforeAll {
            # Guest-only Windows cmdlets need mockable names in Linux CI.
            function Get-Service { param([string[]]$Name) throw "Unmocked guest service check: $Name" }
            function Restart-Service { param([string[]]$Name, [switch]$Force) throw "Unmocked guest service restart: $Name" }
        }
        BeforeEach {
            $script:fxWinArc = [pscustomobject]@{ Name = 'win-app-01'; OsType = 'Windows'; Native = $false; Monitor = $true }
            $script:fxLinuxArc = [pscustomobject]@{ Name = 'lnx-app-01'; OsType = 'Linux'; Native = $false; Monitor = $true }
        }
        It 'has nothing to check on an unmonitored native VM' {
            New-DemoGuestCheckScript -Machine ([pscustomobject]@{ Name = 'win-parent'; OsType = 'Windows'; Native = $true; Monitor = $false }) | Should -BeNullOrEmpty
        }
        It 'checks himds and MonAgentCore on Windows Arc without restarting unless asked' {
            $plain = New-DemoGuestCheckScript -Machine $script:fxWinArc
            $plain.Script | Should -Match 'MonAgentCore'
            $plain.Script | Should -Not -Match 'Restart-Service|AzureMonitorAgent'
            $plain.Services | Should -Be @('himds')
            (New-DemoGuestCheckScript -Machine $script:fxWinArc -Restart).Script | Should -Match 'Restart-Service himds -Force'
        }
        It 'checks each Linux service individually without restarting unless asked' {
            $plain = New-DemoGuestCheckScript -Machine $script:fxLinuxArc
            $plain.Script | Should -Match 'for service in himdsd azuremonitoragent; do sudo systemctl is-active --quiet "\$service"; done'
            $plain.Script | Should -Not -Match 'systemctl restart'
            (New-DemoGuestCheckScript -Machine $script:fxLinuxArc -Restart).Script | Should -Match 'sudo systemctl restart himdsd azuremonitoragent'
        }
        It 'passes a healthy Windows host without a restart and fails a stopped service' {
            Mock Get-Service { [pscustomobject]@{ Name = 'himds'; Status = 'Running' } }
            Mock Restart-Service { throw 'must not restart' }
            Mock Get-Process { [pscustomobject]@{ ProcessName = 'MonAgentCore' } }
            $script = (New-DemoGuestCheckScript -Machine $script:fxWinArc).Script
            & ([scriptblock]::Create($script)) | Should -Contain 'ARC_DEMO_OK'
            Mock Get-Service { [pscustomobject]@{ Name = 'himds'; Status = 'Stopped' } }
            { & ([scriptblock]::Create($script)) } | Should -Throw '*Required Arc service is not running*'
        }
        It 'accepts AMA appearing at five minutes and records pending after ten' -ForEach @(
            @{ AvailableAt = 300; Expected = 'ARC_DEMO_OK' }
            @{ AvailableAt = 900; Expected = 'ARC_DEMO_PENDING' }
        ) {
            $script:fxSeconds = 0
            Mock Get-Service { [pscustomobject]@{ Name = 'himds'; Status = 'Running' } }
            Mock Get-Date { [datetime]::new(2030, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) + [timespan]::FromSeconds($script:fxSeconds) }
            Mock Get-Process { if ($script:fxSeconds -ge $AvailableAt) { [pscustomobject]@{ ProcessName = 'MonAgentCore' } } }
            Mock Start-Sleep { param($Seconds) $script:fxSeconds += $Seconds }
            Mock Write-Progress {}
            $output = & ([scriptblock]::Create((New-DemoGuestCheckScript -Machine $script:fxWinArc).Script)) 3>$null
            $output | Should -Contain $Expected
        }
    }
}

Describe 'Shared guest readiness wait' {
    InModuleScope Common {
        BeforeAll {
            function New-FixtureMachine {
                param([string]$Name, [string]$OsType = 'Windows', [bool]$Native = $false, [bool]$Monitor = $true)
                $infra = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
                $arc = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines'
                [pscustomobject]@{ Name = $Name; Id = "$infra/$Name"; ArcId = $(if ($Native) { $null } else { "$arc/$Name" })
                    OsType = $OsType; Monitor = $Monitor; Native = $Native }
            }
            function Invoke-FixtureWait {
                param([hashtable]$Extra = @{})
                $inventory = [pscustomobject]@{ ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Machines = $script:fxMachines }
                Wait-DemoHostsReady -Inventory $inventory -NamePrefix fixture -AttemptStartedUtc $script:fxStart -WarningAction SilentlyContinue @Extra
            }
            function Get-FixtureElapsed { ($script:fxClock - $script:fxStart).TotalSeconds }
        }
        BeforeEach {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $script:fxStart = [datetime]::new(2030, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $script:fxClock = $script:fxStart
            # Nine hosts: three Linux and five Windows Arc hosts plus an unmonitored native parent.
            $script:fxMachines = @(
                'lnx-app-01', 'lnx-app-02', 'lnx-app-03' | ForEach-Object { New-FixtureMachine $_ 'Linux' }
                'win-app-01', 'win-app-02', 'win-app-03', 'win-sql-01', 'win-sql-02' | ForEach-Object { New-FixtureMachine $_ }
                New-FixtureMachine 'win-parent' 'Windows' $true $false
            )
            # Heartbeat is generated this many seconds after the VM start and is queryable a minute later.
            $script:fxHeartbeatAt = @{}
            foreach ($m in $script:fxMachines | Where-Object Monitor) { $script:fxHeartbeatAt[$m.Name] = 120 }
            $script:fxStaleHeartbeat = @{}
            $script:fxArcStatus = @{}
            $script:fxNestedArc = $null
            $script:fxExt = @{}
            $script:fxVm = @{}
            $script:fxCalls = @{ arc = 0; law = 0; arm = 0; sleeps = 0; armThrows = 0 }
            $script:fxEvents = [System.Collections.Generic.List[string]]::new()
            $script:fxSubmitted = @{}
            $script:fxReceiveError = $null
            $script:fxArcFailures = 0
            $script:fxJobState = 'Completed'
            Mock Get-Date { $script:fxClock }
            Mock Start-Sleep {
                param($Seconds)
                if (++$script:fxCalls.sleeps -gt 400) { throw 'runaway wait loop' }
                $script:fxClock = $script:fxClock.AddSeconds($Seconds)
            }
            Mock Write-Step {}
            Mock Write-Ok {}
            Mock Write-Warn {}
            Mock Get-LawQueryToken { 'law-token' }
            Mock Get-MgmtToken { 'arm-token' }
            Mock Remove-DemoGuestJob {}
            Mock Invoke-DemoAz {
                param($Arguments)
                if ($Arguments[0] -eq 'connectedmachine' -and $Arguments[1] -eq 'list') {
                    $script:fxCalls.arc++
                    $script:fxClock = $script:fxClock.AddSeconds(8)
                    if ($script:fxArcFailures -gt 0) { $script:fxArcFailures--; throw 'transient connectedmachine failure' }
                    $listed = @($script:fxMachines | Where-Object { -not $_.Native } | ForEach-Object {
                        @{ id = $_.ArcId; name = $_.Name; status = $(if ($script:fxArcStatus.ContainsKey($_.Name)) { $script:fxArcStatus[$_.Name] } else { 'Connected' }) } })
                    if ($script:fxNestedArc) { $listed += @{ id = '/arc/arc-guest'; name = 'arc-guest'; status = $script:fxNestedArc } }
                    return (ConvertTo-Json -InputObject $listed -Depth 4)
                }
                if ($Arguments[0] -eq 'monitor') { return '{"customerId":"workspace-customer-id"}' }
                throw "Unexpected Azure CLI call: $($Arguments -join ' ')"
            }
            Mock Get-DemoHeartbeatTimes {
                $script:fxCalls.law++
                $script:fxClock = $script:fxClock.AddSeconds(3)
                $times = @{}
                foreach ($m in $script:fxMachines | Where-Object Monitor) {
                    $scope = $m.ArcId.ToLowerInvariant()
                    if ($script:fxStaleHeartbeat.ContainsKey($m.Name)) { $times[$scope] = $script:fxStaleHeartbeat[$m.Name] }
                    elseif ($script:fxHeartbeatAt.ContainsKey($m.Name) -and (Get-FixtureElapsed) -ge ($script:fxHeartbeatAt[$m.Name] + 60)) {
                        $times[$scope] = $script:fxStart.AddSeconds($script:fxHeartbeatAt[$m.Name])
                    }
                }
                $times
            }
            Mock Get-DemoHostArmStates {
                param($Machines, $Token, $VmStateFor, $TimeoutSeconds)
                $script:fxCalls.arm++
                $script:fxClock = $script:fxClock.AddSeconds(4)
                if ($script:fxArmThrows) { throw 'ARM is unavailable' }
                $vm = @{}
                foreach ($name in @($VmStateFor)) {
                    $vm[$name] = if ($script:fxVm.ContainsKey($name)) { $script:fxVm[$name] }
                    else { [pscustomobject]@{ Power = 'VM running'; AgentReady = $true; Updating = $false; TransitioningExtensions = @() } }
                }
                [pscustomobject]@{ Extensions = $script:fxExt; Vm = $vm; Errors = @{} }
            }
            Mock Invoke-DemoGuestCommand {
                param($Machine, $Script, $Job, [switch]$AsJob, [switch]$PassThru, [switch]$AllowPending)
                if ($AsJob) {
                    $script:fxEvents.Add("submit-$($Machine.Name)")
                    $script:fxSubmitted[$Machine.Name] = $Script
                    return [pscustomobject]@{ Name = "job-$($Machine.Name)"; State = $script:fxJobState; Script = $Script }
                }
                $script:fxEvents.Add("receive-$($Machine.Name)")
                if ($script:fxReceiveError) { throw $script:fxReceiveError }
                [pscustomobject]@{ machineName = $Machine.Name; status = 'pass' }
            }
        }

        It 'passes every host on fresh Heartbeats although Linux extensions are Updating, without Run Command' {
            foreach ($name in 'lnx-app-01', 'lnx-app-02', 'lnx-app-03') {
                $script:fxExt[$name] = [ordered]@{ AzureMonitorLinuxAgent = 'Updating'; 'ChangeTracking-Linux' = 'Updating'; 'MDE.Linux' = 'Updating'; Unwatched = 'Updating' }
            }
            $result = Invoke-FixtureWait
            $result.Status | Should -Be 'pass'
            @($result.Hosts | Where-Object status -ne 'pass').Count | Should -Be 0
            $result.Hosts.Count | Should -Be 9
            $linux = $result.Hosts | Where-Object machineName -eq 'lnx-app-01'
            $linux.method | Should -Be 'arm+heartbeat'
            $linux.startedAtUtc | Should -Be $script:fxStart.ToString('o')
            $linux.lastHeartbeatUtc | Should -Be $script:fxStart.AddSeconds(120).ToString('o')
            $linux.extensionStates['MDE.Linux'] | Should -Be 'Updating'
            $linux.extensionStates.Contains('Unwatched') | Should -BeFalse
            ($linux.warnings -join ' ') | Should -Match 'MDE.Linux Updating.*not a gate'
            ($result.Hosts | Where-Object machineName -eq 'win-parent').method | Should -Be 'arm'
            Should -Invoke Invoke-DemoGuestCommand -Times 0
            Get-FixtureElapsed | Should -BeLessThan 300
        }
        It 'does not read Arc, Heartbeat or ARM state for a host that needs none' {
            $script:fxMachines = @(New-FixtureMachine 'win-parent' 'Windows' $true $false)
            $result = Invoke-FixtureWait
            $result.Status | Should -Be 'pass'
            $script:fxCalls.arc | Should -Be 0
            $script:fxCalls.law | Should -Be 0
        }
        It 'leaves only the host without a Heartbeat pending at the deadline, within deadline plus 60 seconds' {
            $script:fxHeartbeatAt.Remove('win-app-03')
            $result = Invoke-FixtureWait
            $result.Status | Should -Be 'pending'
            @($result.Hosts | Where-Object status -eq 'pending').machineName | Should -Be @('win-app-03')
            @($result.Hosts | Where-Object status -eq 'pass').Count | Should -Be 8
            $pending = $result.Hosts | Where-Object machineName -eq 'win-app-03'
            $pending.lastHeartbeatUtc | Should -BeNullOrEmpty
            $pending.message | Should -Match 'Pending, not failed'
            Get-FixtureElapsed | Should -BeGreaterOrEqual 720
            Get-FixtureElapsed | Should -BeLessOrEqual (720 + 60)
            Should -Invoke Invoke-DemoGuestCommand -Times 0
        }
        It 'finishes every blocked host at the shared deadline, not one wait per host' {
            $script:fxHeartbeatAt.Clear()
            $script:fxJobState = 'Running'
            $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'Always' }
            $result.Status | Should -Be 'pending'
            @($result.Hosts | Where-Object status -eq 'pending').Count | Should -Be 8
            @($result.Hosts | Where-Object status -eq 'pass').machineName | Should -Be @('win-parent')
            Get-FixtureElapsed | Should -BeGreaterOrEqual 720
            Get-FixtureElapsed | Should -BeLessOrEqual (720 + 60)
            Should -Invoke Remove-DemoGuestJob -Times 8 -Exactly -ParameterFilter { $null -ne $Job }
            @($script:fxEvents | Where-Object { $_ -like 'receive-*' }).Count | Should -Be 0
        }
        It 'does not let a stale Heartbeat from before the VM start pass a host' {
            $script:fxStaleHeartbeat['win-app-03'] = $script:fxStart.AddHours(-3)
            $script:fxHeartbeatAt.Remove('win-app-03')
            $result = Invoke-FixtureWait -Extra @{ DeadlineMinutes = 4 }
            $host03 = $result.Hosts | Where-Object machineName -eq 'win-app-03'
            $host03.status | Should -Be 'pending'
            $host03.lastHeartbeatUtc | Should -Be $script:fxStart.AddHours(-3).ToString('o')
        }
        It 'uses the recorded start time of each VM as the Heartbeat cutoff' {
            $started = @{ $script:fxMachines[0].Id = $script:fxStart.AddSeconds(150) }
            $result = Invoke-FixtureWait -Extra @{ StartedAtUtc = $started; DeadlineMinutes = 4 }
            ($result.Hosts | Where-Object machineName -eq 'lnx-app-01').status | Should -Be 'pending'
            ($result.Hosts | Where-Object machineName -eq 'lnx-app-01').startedAtUtc | Should -Be $script:fxStart.AddSeconds(150).ToString('o')
            ($result.Hosts | Where-Object machineName -eq 'lnx-app-02').status | Should -Be 'pass'
        }
        It 'fails a host whose AMA extension is Failed and has no Heartbeat' {
            $script:fxHeartbeatAt.Remove('win-app-03')
            $script:fxExt['win-app-03'] = [ordered]@{ AzureMonitorWindowsAgent = 'Failed' }
            $result = Invoke-FixtureWait -Extra @{ DeadlineMinutes = 4 }
            $result.Status | Should -Be 'fail'
            $failed = $result.Hosts | Where-Object machineName -eq 'win-app-03'
            $failed.status | Should -Be 'fail'
            $failed.message | Should -Match 'AMA extension is Failed'
        }
        It 'keeps a failed Change Tracking extension a warning when the Heartbeat is fresh' {
            $script:fxExt['win-app-01'] = [ordered]@{ AzureMonitorWindowsAgent = 'Succeeded'; 'ChangeTracking-Windows' = 'Failed' }
            $result = Invoke-FixtureWait
            $result.Status | Should -Be 'pass'
            (($result.Hosts | Where-Object machineName -eq 'win-app-01').warnings -join ' ') | Should -Match 'ChangeTracking-Windows is Failed \(not a gate\)'
        }
        It 'fails a host whose VM is no longer running at the deadline' {
            $script:fxHeartbeatAt.Remove('win-app-03')
            $script:fxVm['win-app-03'] = [pscustomobject]@{ Power = 'VM deallocated'; AgentReady = $false; Updating = $false; TransitioningExtensions = @() }
            $result = Invoke-FixtureWait -Extra @{ DeadlineMinutes = 4 }
            $result.Status | Should -Be 'fail'
            ($result.Hosts | Where-Object machineName -eq 'win-app-03').message | Should -Match 'not running \(power state: VM deallocated\)'
        }
        It 'fails a host whose Arc identity never connects' {
            $script:fxArcStatus['win-app-03'] = 'Disconnected'
            $result = Invoke-FixtureWait -Extra @{ DeadlineMinutes = 4 }
            $result.Status | Should -Be 'fail'
            ($result.Hosts | Where-Object machineName -eq 'win-app-03').message | Should -Match 'Arc identity is not Connected after 4 minutes \(last status: Disconnected\)'
        }
        It 'does not let a soft ARM read failure fail or stall the wait' {
            $script:fxArmThrows = $true
            try { $result = Invoke-FixtureWait } finally { $script:fxArmThrows = $false }
            $result.Status | Should -Be 'pass'
            Get-FixtureElapsed | Should -BeLessThan 300
        }
        It 'retries a transient read failure once and then continues' {
            $script:fxArcFailures = 1
            $result = Invoke-FixtureWait
            $result.Status | Should -Be 'pass'
            Should -Invoke Write-Warn -Times 1 -Exactly -ParameterFilter { $Message -match 'read failed \(1 of 3\)' }
        }
        It 'surfaces a persistent read failure after three attempts' {
            $script:fxArcFailures = 99
            { Invoke-FixtureWait } | Should -Throw '*Inspection failed while waiting for guest readiness*transient connectedmachine failure*'
            $script:fxCalls.arc | Should -Be 3
        }

        Context 'Run Command guest checks' {
            It 'submits every Always check before receiving the first result' {
                $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'Always' }
                $result.Status | Should -Be 'pass'
                $submits = @($script:fxEvents | Where-Object { $_ -like 'submit-*' })
                $submits.Count | Should -Be 8
                $script:fxEvents.IndexOf(($script:fxEvents | Where-Object { $_ -like 'receive-*' } | Select-Object -First 1)) | Should -Be 8
                ($result.Hosts | Where-Object machineName -eq 'win-app-01').method | Should -Be 'arm+heartbeat+run-command'
                ($result.Hosts | Where-Object machineName -eq 'win-app-01').completion.status | Should -Be 'pass'
                ($result.Hosts | Where-Object machineName -eq 'win-parent').method | Should -Be 'arm'
            }
            It 'restarts services only with RepairStalledAgents and only on hosts started in this attempt' {
                $started = @{ $script:fxMachines[3].Id = $script:fxStart }
                Invoke-FixtureWait -Extra @{ GuestChecks = 'Always' } | Out-Null
                @($script:fxSubmitted.Values | Where-Object { $_ -match 'Restart-Service|systemctl restart' }).Count | Should -Be 0
                $script:fxSubmitted.Clear()
                $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'Always'; RepairStalledAgents = $true; StartedAtUtc = $started }
                @($script:fxSubmitted.Keys | Where-Object { $script:fxSubmitted[$_] -match 'Restart-Service|systemctl restart' }) | Should -Be @('win-app-01')
                ($result.Hosts | Where-Object machineName -eq 'win-app-01').restartedServices | Should -Be @('himds')
            }
            It 'fails a host whose guest check reports a failure and keeps the others' {
                $script:fxReceiveError = 'Required Arc service is not running.'
                $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'Always' }
                $result.Status | Should -Be 'fail'
                @($result.Hosts | Where-Object status -eq 'fail').Count | Should -Be 8
                ($result.Hosts | Where-Object machineName -eq 'win-parent').status | Should -Be 'pass'
                ($result.Hosts | Where-Object machineName -eq 'win-app-01').message | Should -Be 'Required Arc service is not running.'
            }
            It 'checks only a stalled host, and only when the VM would not queue the command' {
                $script:fxHeartbeatAt.Remove('lnx-app-01')
                $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'WhenStalled'; StallMinutes = 3 }
                $script:fxEvents | Should -Be @('submit-lnx-app-01', 'receive-lnx-app-01')
                $stalled = $result.Hosts | Where-Object machineName -eq 'lnx-app-01'
                $stalled.status | Should -Be 'pending'
                $stalled.method | Should -Be 'arm+heartbeat+run-command'
                $stalled.completion.status | Should -Be 'pass'
            }
            It 'skips the stalled-host check while a VM extension operation is in flight and says so once' {
                $script:fxHeartbeatAt.Remove('lnx-app-01')
                $script:fxVm['lnx-app-01'] = [pscustomobject]@{ Power = 'VM running'; AgentReady = $true; Updating = $true; TransitioningExtensions = @('MDE.Linux') }
                $result = Invoke-FixtureWait -Extra @{ GuestChecks = 'WhenStalled'; StallMinutes = 3 }
                $script:fxEvents.Count | Should -Be 0
                $stalled = $result.Hosts | Where-Object machineName -eq 'lnx-app-01'
                $stalled.status | Should -Be 'pending'
                @($stalled.warnings | Where-Object { $_ -match 'would queue' }).Count | Should -Be 1
            }
        }

        Context 'nested guest start' {
            BeforeEach {
                $script:fxNested = [pscustomobject]@{
                    Parent = $script:fxMachines | Where-Object Name -eq 'win-sql-02'; GuestVmName = 'guest'; ArcMachineName = 'arc-guest'
                    Job = [pscustomobject]@{ Name = 'nested'; State = 'Completed' }; SubmittedUtc = $script:fxStart; BudgetMinutes = 5
                }
                $script:fxNestedArc = 'Connected'
            }
            It 'passes when the start command succeeds and the guest Arc machine connects' {
                $result = Invoke-FixtureWait -Extra @{ NestedGuest = $script:fxNested }
                $result.Status | Should -Be 'pass'
                $result.NestedGuest.status | Should -Be 'pass'
                $result.NestedGuest.startCommand | Should -Be 'pass'
                $script:fxEvents | Should -Be @('receive-win-sql-02')
            }
            It 'stops waiting for a start command after its own five-minute budget and relies on the Arc connection' {
                $script:fxNested.Job.State = 'Running'
                $result = Invoke-FixtureWait -Extra @{ NestedGuest = $script:fxNested }
                $result.Status | Should -Be 'pass'
                $result.NestedGuest.startCommand | Should -Be 'timeout'
                $result.NestedGuest.status | Should -Be 'pass'
                $result.NestedGuest.message | Should -Match 'did not finish within 5 minutes'
                Get-FixtureElapsed | Should -BeGreaterOrEqual 300
                Get-FixtureElapsed | Should -BeLessThan 400
                Should -Invoke Remove-DemoGuestJob -Times 1 -ParameterFilter { $Job.Name -eq 'nested' }
            }
            It 'fails the guest, not the hosts, when its start command fails, without waiting for the deadline' {
                $script:fxReceiveError = 'Guest start failed.'
                $result = Invoke-FixtureWait -Extra @{ NestedGuest = $script:fxNested }
                $result.Status | Should -Be 'fail'
                $result.NestedGuest.status | Should -Be 'fail'
                $result.NestedGuest.startCommand | Should -Be 'fail'
                $result.NestedGuest.message | Should -Be 'Guest start failed.'
                ($result.Hosts | Where-Object status -ne 'pass').Count | Should -Be 0
                Get-FixtureElapsed | Should -BeLessThan 300
            }
            It 'fails the guest when its Arc machine is not Connected at the deadline' {
                $script:fxNestedArc = 'Disconnected'
                $result = Invoke-FixtureWait -Extra @{ NestedGuest = $script:fxNested; DeadlineMinutes = 4 }
                $result.NestedGuest.status | Should -Be 'fail'
                $result.NestedGuest.message | Should -Match 'Arc machine is not Connected after 4 minutes \(last status: Disconnected\)'
            }
        }
    }
}

Describe 'Readiness treats extension state as a soft diagnostic' {
    InModuleScope Common {
        BeforeEach {
            $script:DemoSubscription = '11111111-1111-1111-1111-111111111111'
            $script:fxArcRg = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture/providers/Microsoft.HybridCompute/machines'
            $script:fxHeartbeats = @()
            $script:fxConnectedMinutes = 90
            $script:fxExtState = 'Updating'
            Mock Get-DemoNetworkState { [pscustomobject]@{ NatId = '/nat'; PublicIpId = '/pip'; Nat = $null; PublicIp = $null; Subnet = @{ id = '/subnet' } } }
            Mock Get-DemoHeartbeatIds { $script:fxHeartbeats }
            Mock Invoke-DemoAz {
                param($Arguments)
                $command = $Arguments[0..2] -join ' '
                if ($Arguments[0] -eq 'group') { return '{"properties":{"provisioningState":"Succeeded"}}' }
                if ($command -eq 'connectedmachine list -g') {
                    $changed = (Get-Date).ToUniversalTime().AddMinutes(-$script:fxConnectedMinutes).ToString('o')
                    return (ConvertTo-Json -InputObject @(@{ id = "$script:fxArcRg/lnx-app-01"; status = 'Connected'; lastStatusChange = $changed }
                        @{ id = "$script:fxArcRg/win-app-01"; status = 'Connected'; lastStatusChange = $changed }))
                }
                if ($Arguments[0] -eq 'monitor' -and $Arguments[1] -eq 'log-analytics') { return '{"customerId":"workspace"}' }
                if ($Arguments[0] -eq 'vm' -and $Arguments[1] -eq 'extension') {
                    return (ConvertTo-Json -InputObject @(@{ name = 'AzureMonitorLinuxAgent'; provisioningState = $script:fxExtState }
                        @{ name = 'ChangeTracking-Linux'; provisioningState = $script:fxExtState }))
                }
                if ($Arguments[0] -eq 'connectedmachine' -and $Arguments[1] -eq 'extension') {
                    return (ConvertTo-Json -InputObject @(@{ name = 'AzureMonitorWindowsAgent'; properties = @{ provisioningState = $script:fxExtState } }))
                }
                return '[]'
            }
            $infra = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-fixture-infra/providers/Microsoft.Compute/virtualMachines'
            $script:fxInventory = [pscustomobject]@{
                ArcRg = 'rg-fixture'; InfraRg = 'rg-fixture-infra'; Resources = @(); AksClusterIds = @(); ContainerAppIds = @()
                Machines = @(
                    [pscustomobject]@{ Name = 'lnx-app-01'; Id = "$infra/lnx-app-01"; ArcId = "$script:fxArcRg/lnx-app-01"; Native = $false; Monitor = $true
                        VmInsights = $false; ChangeTracking = $true; OsType = 'Linux'; Actual = @{ powerState = 'VM running' } }
                    [pscustomobject]@{ Name = 'win-app-01'; Id = "$infra/win-app-01"; ArcId = "$script:fxArcRg/win-app-01"; Native = $false; Monitor = $true
                        VmInsights = $false; ChangeTracking = $false; OsType = 'Windows'; Actual = @{ powerState = 'VM running' } })
            }
        }
        It 'makes every extension row non-required with the state, age and a pointer in the message' {
            $script:fxHeartbeats = @("$($script:fxArcRg)/lnx-app-01".ToLowerInvariant(), "$($script:fxArcRg)/win-app-01".ToLowerInvariant())
            $checks = @(Get-DemoReadinessChecks -Inventory $script:fxInventory -NamePrefix fixture -DesiredState Active)
            $extensions = @($checks | Where-Object id -like 'extension/*')
            $extensions.Count | Should -Be 3
            @($extensions | Where-Object required).Count | Should -Be 0
            $linux = $checks | Where-Object id -eq 'extension/lnx-app-01/AzureMonitorLinuxAgent'
            $linux.status | Should -Be 'pending'
            $linux.observed | Should -Be 'Updating'
            $linux.message | Should -Match 'ARM state Updating; Arc connected 9\d min ago'
            $linux.message | Should -Match 'Soft warning, not a readiness gate'
            $linux.message | Should -Match 'docs/troubleshooting.md'
            ($checks | Where-Object id -eq 'extension/win-app-01/AzureMonitorWindowsAgent').status | Should -Be 'pending'
            @($checks | Where-Object { $_.id -like 'heartbeat/*' -and $_.status -ne 'pass' }).Count | Should -Be 0
        }
        It 'leaves the pointer out while the host has only just connected' {
            $script:fxConnectedMinutes = 5
            $script:fxHeartbeats = @("$($script:fxArcRg)/lnx-app-01".ToLowerInvariant(), "$($script:fxArcRg)/win-app-01".ToLowerInvariant())
            $linux = Get-DemoReadinessChecks -Inventory $script:fxInventory -NamePrefix fixture -DesiredState Active | Where-Object id -eq 'extension/lnx-app-01/AzureMonitorLinuxAgent'
            $linux.message | Should -Match 'Arc connected [45] min ago'
            $linux.message | Should -Not -Match 'docs/troubleshooting.md'
        }
        It 'keeps a pending Heartbeat pending while the AMA extension is only Updating' {
            $checks = @(Get-DemoReadinessChecks -Inventory $script:fxInventory -NamePrefix fixture -DesiredState Active)
            $heartbeat = $checks | Where-Object id -eq 'heartbeat/lnx-app-01'
            $heartbeat.required | Should -BeTrue
            $heartbeat.status | Should -Be 'pending'
        }
        It 'does not forgive a Failed AMA extension with no Heartbeat as telemetry lag' {
            $script:fxExtState = 'Failed'
            $checks = @(Get-DemoReadinessChecks -Inventory $script:fxInventory -NamePrefix fixture -DesiredState Active)
            $heartbeat = $checks | Where-Object id -eq 'heartbeat/lnx-app-01'
            $heartbeat.required | Should -BeTrue
            $heartbeat.status | Should -Be 'fail'
            $heartbeat.message | Should -Match 'not telemetry lag'
            ($checks | Where-Object id -eq 'extension/lnx-app-01/AzureMonitorLinuxAgent').required | Should -BeFalse
        }
        It 'passes a Heartbeat even if the AMA extension is Failed' {
            $script:fxExtState = 'Failed'
            $script:fxHeartbeats = @("$($script:fxArcRg)/lnx-app-01".ToLowerInvariant())
            $heartbeat = Get-DemoReadinessChecks -Inventory $script:fxInventory -NamePrefix fixture -DesiredState Active | Where-Object id -eq 'heartbeat/lnx-app-01'
            $heartbeat.status | Should -Be 'pass'
        }
    }
}
