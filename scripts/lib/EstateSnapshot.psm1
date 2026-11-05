#Requires -Version 7.4
# Read-only estate snapshot and parity evaluation. Every read is a list/show/get; a denied or failed read is
# recorded verbatim in its own section and is never retried through another tool.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

# Public Azure built-in role IDs, used only to label role assignments.
$script:KnownRole = @{
    '749f88d5-cbae-40b8-bcfc-e573ddc772fa' = 'Monitoring Contributor'
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' = 'Log Analytics Contributor'
    '73c42c96-874c-492b-b04d-ab87d138a893' = 'Log Analytics Reader'
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
    'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
    'e79298df-d852-4c6d-84f9-5d13249d1e55' = 'SRE Agent Administrator'
}
$script:GroupCache = @{}

function Get-SnapshotValue {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $null }
            $current = $current[$part]
            continue
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    $current
}

function Test-SnapshotKey {
    # Tells a field that was captured as empty from one an older snapshot never captured.
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    $null -ne $Object.PSObject.Properties[$Name]
}

function ConvertTo-SnapshotDate {
    # A snapshot read back from JSON holds [datetime] values and a live one holds ISO text. Never go through a
    # culture-bound string: MM/dd/yyyy text parses as a different date under en-AU or de-DE.
    param([AllowNull()]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) { return [DateTimeOffset]::new($Value.ToUniversalTime()) }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
}

function Get-SnapshotJson {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowNotFound)
    $raw = Invoke-DemoAz -Arguments $Arguments -AllowNotFound:$AllowNotFound
    if ($null -eq $raw) { return }
    $text = (@($raw) -join "`n").Trim()
    if ($text) { $text | ConvertFrom-Json }
}

function Test-SnapshotGroup {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:GroupCache.ContainsKey($Name)) {
        $script:GroupCache[$Name] = [bool](Invoke-DemoAz -Arguments @('group', 'exists', '-n', $Name, '-o', 'json') | ConvertFrom-Json)
    }
    $script:GroupCache[$Name]
}

function Invoke-SnapshotSection {
    param([Parameter(Mandatory)][scriptblock]$Read)
    try { [ordered]@{ status = 'ok'; data = (& $Read) } }
    catch { [ordered]@{ status = 'error'; error = $_.Exception.Message } }
}

function Get-DemoEstateSnapshot {
    <#
    .SYNOPSIS
        Reads the demo estate into one JSON-ready object. Read-only.
    .DESCRIPTION
        The snapshot holds names, types, sizes, states and credential metadata only: no secret
        values, no vault contents. It is private evidence; keep it outside git.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId, [Parameter(Mandatory)][string]$NamePrefix)
    Assert-DemoName $NamePrefix
    Initialize-DemoContext -SubscriptionId $SubscriptionId -TenantId $TenantId
    $script:GroupCache = @{}
    $groups = [ordered]@{ arc = "rg-$NamePrefix"; infra = "rg-$NamePrefix-infra"; sre = "rg-$NamePrefix-sre" }
    $arcId = "/subscriptions/$SubscriptionId/resourceGroups/$($groups.arc)/providers/Microsoft.HybridCompute/machines"
    $base = "https://management.azure.com/subscriptions/$SubscriptionId"
    $sections = [ordered]@{}

    $sections['groups'] = Invoke-SnapshotSection {
        $result = [ordered]@{}
        foreach ($key in $groups.Keys) {
            $name = $groups[$key]
            $resources = if (Test-SnapshotGroup $name) { @(Get-SnapshotJson @('resource', 'list', '-g', $name, '-o', 'json')) } else { @() }
            $result[$key] = [ordered]@{ name = $name; exists = (Test-SnapshotGroup $name)
                resources = @($resources | ForEach-Object { [ordered]@{ name = (Get-SnapshotValue $_ 'name'); type = (Get-SnapshotValue $_ 'type')
                    location = (Get-SnapshotValue $_ 'location'); tags = (Get-SnapshotValue $_ 'tags') } }) }
        }
        $result
    }
    $sections['vms'] = Invoke-SnapshotSection {
        if (-not (Test-SnapshotGroup $groups.infra)) { return , @() }
        $machines = @(Get-SnapshotJson @('vm', 'list', '-g', $groups.infra, '-d', '-o', 'json')) | ForEach-Object {
            [ordered]@{ name = (Get-SnapshotValue $_ 'name'); size = (Get-SnapshotValue $_ 'hardwareProfile.vmSize'); powerState = (Get-SnapshotValue $_ 'powerState')
                osType = (Get-SnapshotValue $_ 'storageProfile.osDisk.osType'); osDiskSku = (Get-SnapshotValue $_ 'storageProfile.osDisk.managedDisk.storageAccountType')
                dataDisks = @(@(Get-SnapshotValue $_ 'storageProfile.dataDisks') | Where-Object { $_ } | ForEach-Object {
                    [ordered]@{ lun = (Get-SnapshotValue $_ 'lun'); sizeGb = (Get-SnapshotValue $_ 'diskSizeGb'); sku = (Get-SnapshotValue $_ 'managedDisk.storageAccountType') } }) }
        }
        , @($machines)
    }
    $sections['arcMachines'] = Invoke-SnapshotSection {
        if (-not (Test-SnapshotGroup $groups.arc)) { return , @() }
        $machines = @(Get-SnapshotJson @('connectedmachine', 'list', '-g', $groups.arc, '-o', 'json')) | ForEach-Object {
            [ordered]@{ name = (Get-SnapshotValue $_ 'name'); status = (Get-SnapshotValue $_ 'status'); osType = (Get-SnapshotValue $_ 'osType'); agentVersion = (Get-SnapshotValue $_ 'agentVersion')
                tags = (Get-SnapshotValue $_ 'tags') }
        }
        , @($machines)
    }
    $sections['dcrAssociations'] = Invoke-SnapshotSection {
        if ($sections['arcMachines'].status -ne 'ok') { throw 'The Arc machine list is unavailable, so associations were not read.' }
        $associations = foreach ($machine in $sections['arcMachines'].data) {
            $links = @(Get-SnapshotJson @('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', "$arcId/$($machine.name)", '-o', 'json'))
            [ordered]@{ machine = $machine.name; rules = @($links | ForEach-Object { ((Get-SnapshotValue $_ 'dataCollectionRuleId') -split '/')[-1] }) }
        }
        , @($associations)
    }
    $sections['alerts'] = Invoke-SnapshotSection {
        $rules = if (Test-SnapshotGroup $groups.arc) { (Invoke-AzRest -Method Get -Url "$base/resourceGroups/$($groups.arc)/providers/Microsoft.Insights/scheduledQueryRules?api-version=2023-03-15-preview").value } else { @() }
        $metric = if (Test-SnapshotGroup $groups.infra) { (Invoke-AzRest -Method Get -Url "$base/resourceGroups/$($groups.infra)/providers/Microsoft.Insights/metricAlerts?api-version=2018-03-01").value } else { @() }
        [ordered]@{
            scheduledQueryRules = @($rules | ForEach-Object { [ordered]@{ name = $_.name; enabled = (Get-SnapshotValue $_ 'properties.enabled'); severity = (Get-SnapshotValue $_ 'properties.severity')
                evaluationFrequency = (Get-SnapshotValue $_ 'properties.evaluationFrequency'); windowSize = (Get-SnapshotValue $_ 'properties.windowSize') } })
            metricAlerts = @($metric | ForEach-Object { [ordered]@{ name = $_.name; enabled = (Get-SnapshotValue $_ 'properties.enabled') } })
        }
    }
    $sections['workbooks'] = Invoke-SnapshotSection {
        if (-not (Test-SnapshotGroup $groups.arc)) { return , @() }
        $books = (Invoke-AzRest -Method Get -Url "$base/resourceGroups/$($groups.arc)/providers/Microsoft.Insights/workbooks?category=workbook&api-version=2023-06-01").value
        , @($books | ForEach-Object { [ordered]@{ name = $_.name; displayName = (Get-SnapshotValue $_ 'properties.displayName'); tags = (Get-SnapshotValue $_ 'tags') } })
    }
    $sections['workspace'] = Invoke-SnapshotSection {
        $workspace = if (Test-SnapshotGroup $groups.arc) { Get-SnapshotJson @('monitor', 'log-analytics', 'workspace', 'show', '-g', $groups.arc, '-n', "law-$NamePrefix", '-o', 'json') -AllowNotFound }
        $deleted = (Invoke-AzRest -Method Get -Url "$base/providers/Microsoft.OperationalInsights/deletedWorkspaces?api-version=2020-08-01").value
        [ordered]@{
            found = [bool]$workspace; retentionInDays = (Get-SnapshotValue $workspace 'retentionInDays'); sku = (Get-SnapshotValue $workspace 'sku.name')
            dailyQuotaGb = (Get-SnapshotValue $workspace 'workspaceCapping.dailyQuotaGb')
            softDeleted = @($deleted | Where-Object { $_.name -eq "law-$NamePrefix" } | ForEach-Object { $_.name })
        }
    }
    $sections['keyVaults'] = Invoke-SnapshotSection {
        $vaults = if (Test-SnapshotGroup $groups.infra) { @(Get-SnapshotJson @('keyvault', 'list', '-g', $groups.infra, '-o', 'json')) } else { @() }
        $prefix = "kv-$($NamePrefix -replace '-', '')"
        [ordered]@{
            vaults = @($vaults | ForEach-Object { [ordered]@{ name = (Get-SnapshotValue $_ 'name'); publicNetworkAccess = (Get-SnapshotValue $_ 'properties.publicNetworkAccess') } })
            softDeleted = @(@(Get-SnapshotJson @('keyvault', 'list-deleted', '-o', 'json')) | Where-Object { (Get-SnapshotValue $_ 'name') -like "$prefix*" } |
                ForEach-Object { [ordered]@{ name = (Get-SnapshotValue $_ 'name'); scheduledPurgeDate = (Get-SnapshotValue $_ 'properties.scheduledPurgeDate') } })
        }
    }
    $sections['subscription'] = Invoke-SnapshotSection {
        $scope = "/subscriptions/$SubscriptionId"
        $policies = foreach ($name in "mcsb-$NamePrefix", "nist-$NamePrefix") {
            if (Get-SnapshotJson @('policy', 'assignment', 'show', '-n', $name, '--scope', $scope, '-o', 'json') -AllowNotFound) { $name }
        }
        $budget = Get-SnapshotJson @('consumption', 'budget', 'show', '--budget-name', "budget-$NamePrefix", '-o', 'json') -AllowNotFound
        $pricing = Get-SnapshotJson @('security', 'pricing', 'list', '-o', 'json')
        $plans = if ($null -ne (Get-SnapshotValue $pricing 'value')) { $pricing.value } else { $pricing }
        [ordered]@{
            policyAssignments = @($policies)
            budgets = @(if ($budget) { "budget-$NamePrefix" })
            defender = @($plans | ForEach-Object { [ordered]@{ name = (Get-SnapshotValue $_ 'name'); tier = (Get-SnapshotValue $_ 'pricingTier'); subPlan = (Get-SnapshotValue $_ 'subPlan') } })
        }
    }
    $sections['onboardingApp'] = Invoke-SnapshotSection {
        $name = "sp-$NamePrefix-onboard"
        $app = @(Get-SnapshotJson @('ad', 'app', 'list', '--display-name', $name, '-o', 'json') | Where-Object { (Get-SnapshotValue $_ 'displayName') -eq $name })
        if ($app.Count -gt 1) { throw "More than one application is named $name." }
        [ordered]@{
            found = ($app.Count -eq 1)
            credentials = @(if ($app.Count -eq 1) { @(Get-SnapshotValue $app[0] 'passwordCredentials') | Where-Object { $_ } | ForEach-Object {
                [ordered]@{ displayName = (Get-SnapshotValue $_ 'displayName'); keyId = (Get-SnapshotValue $_ 'keyId')
                    startDateTime = (Get-SnapshotValue $_ 'startDateTime'); endDateTime = (Get-SnapshotValue $_ 'endDateTime') } } })
        }
    }
    $sections['sre'] = Invoke-SnapshotSection {
        if (-not (Test-SnapshotGroup $groups.sre)) { return [ordered]@{ exists = $false; identities = @() } }
        $identities = @(Get-SnapshotJson @('identity', 'list', '-g', $groups.sre, '-o', 'json'))
        [ordered]@{
            exists = $true
            identities = @($identities | ForEach-Object {
                $principal = Get-SnapshotValue $_ 'principalId'
                $assignments = if ($principal) { (Invoke-AzRest -Method Get -Url "$base/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=principalId%20eq%20'$principal'").value } else { @() }
                [ordered]@{ name = (Get-SnapshotValue $_ 'name'); roleAssignments = @($assignments | ForEach-Object {
                    $roleId = ((Get-SnapshotValue $_ 'properties.roleDefinitionId') -split '/')[-1]
                    [ordered]@{ role = $(if ($script:KnownRole.ContainsKey($roleId)) { $script:KnownRole[$roleId] } else { $roleId }); scope = (Get-SnapshotValue $_ 'properties.scope') } }) }
            })
        }
    }
    $sections['fleet'] = Invoke-SnapshotSection {
        $arcGroup = $groups.arc
        $manifest = @(Get-SnapshotJson @('deployment', 'sub', 'list', '-o', 'json') | Where-Object {
            (Get-SnapshotValue $_ 'properties.provisioningState') -eq 'Succeeded' -and (Get-SnapshotValue $_ 'properties.outputs.arcResourceGroup.value') -eq $arcGroup -and
            $null -ne (Get-SnapshotValue $_ 'properties.outputs.vmFleet.value') } | Sort-Object { Get-SnapshotValue $_ 'properties.timestamp' } -Descending)
        [ordered]@{
            deployment = $(if ($manifest) { $manifest[0].name } else { '' })
            machines = @(if ($manifest) { @($manifest[0].properties.outputs.vmFleet.value) | Where-Object { Get-SnapshotValue $_ 'deployed' } |
                ForEach-Object { [ordered]@{ name = (Get-SnapshotValue $_ 'name'); osType = (Get-SnapshotValue $_ 'osType'); role = (Get-SnapshotValue $_ 'role'); osTier = (Get-SnapshotValue $_ 'osTier') } } })
            azureVmNames = @(if ($manifest) { @(Get-SnapshotValue $manifest[0] 'properties.outputs.azureVmNames.value') | Where-Object { $_ } })
        }
    }
    [ordered]@{
        schemaVersion = 1; workload = 'arc-demo-inventory'; capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        subscriptionId = "$SubscriptionId"; tenantId = "$TenantId"; namePrefix = $NamePrefix; sections = $sections
    }
}

function Get-SnapshotSection {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Name)
    $section = Get-SnapshotValue $Snapshot "sections.$Name"
    if ($null -eq $section) { return [pscustomobject]@{ Ok = $false; Data = $null; Error = "Section '$Name' is missing from the snapshot." } }
    $status = Get-SnapshotValue $section 'status'
    [pscustomobject]@{ Ok = ($status -eq 'ok'); Data = (Get-SnapshotValue $section 'data'); Error = [string](Get-SnapshotValue $section 'error') }
}

function Test-DemoEstateParity {
    <#
    .SYNOPSIS
        Compares a snapshot with the expected-object list. Pure function: it reads no Azure state.
    .DESCRIPTION
        Every check is required. Fleet checks follow the retained deployment manifest, so the
        expected hosts come from what the deployment says it created, not from a hard-coded list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$NamePrefix,
        [string[]]$Feature = @(),
        [string]$NestedParentVmName = '',
        [string]$NestedArcMachineName = '',
        [string[]]$KeepParkedVmNames = @()
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $subscriptionId = [string](Get-SnapshotValue $Snapshot 'subscriptionId')
    $add = { param($id, $expected, $observed, $ok, $message) $checks.Add((New-DemoCheck $id '' $expected $observed $(if ($ok) { 'pass' } else { 'fail' }) -Message $message)) }
    $unavailable = { param($id, $expected, $section) $checks.Add((New-DemoCheck $id '' $expected $null 'fail' -Message "Snapshot data unavailable: $($section.Error)")) }
    foreach ($section in 'groups', 'vms', 'arcMachines', 'dcrAssociations', 'alerts', 'workbooks', 'workspace', 'keyVaults', 'subscription', 'onboardingApp', 'sre', 'fleet') {
        $state = Get-SnapshotSection $Snapshot $section
        & $add "snapshot/$section" 'section read without error' $(if ($state.Ok) { 'ok' } else { 'error' }) $state.Ok $state.Error
    }
    $expandName = { param($text) ([string]$text).Replace('{prefix}', $NamePrefix) }
    foreach ($rule in @($Expected.rules)) {
        $ruleFeature = [string](Get-SnapshotValue $rule 'feature')
        if ($ruleFeature -and $ruleFeature -notin $Feature) { continue }
        $id = [string]$rule.id
        switch ([string](Get-SnapshotValue $rule 'kind')) {
            'policy' {
                $state = Get-SnapshotSection $Snapshot 'subscription'
                $name = & $expandName $rule.name
                if ($state.Ok) { & $add $id "policy assignment $name" @($state.Data.policyAssignments) ($name -in @($state.Data.policyAssignments)) '' } else { & $unavailable $id "policy assignment $name" $state }
            }
            'budget' {
                $state = Get-SnapshotSection $Snapshot 'subscription'
                $name = & $expandName $rule.name
                if ($state.Ok) { & $add $id "budget $name" @($state.Data.budgets) ($name -in @($state.Data.budgets)) '' } else { & $unavailable $id "budget $name" $state }
            }
            'defender' {
                $state = Get-SnapshotSection $Snapshot 'subscription'
                if (-not $state.Ok) { & $unavailable $id "Defender $($rule.plan) $($rule.tier)" $state; continue }
                $plan = @($state.Data.defender | Where-Object { $_.name -eq $rule.plan }) | Select-Object -First 1
                $tier = if ($plan) { [string]$plan.tier } else { 'absent' }
                & $add $id "$($rule.plan) tier $($rule.tier)" $tier ($tier -eq $rule.tier) ''
            }
            'identityRole' {
                $state = Get-SnapshotSection $Snapshot 'sre'
                if (-not $state.Ok) { & $unavailable $id "$($rule.role) at subscription scope" $state; continue }
                $scope = "/subscriptions/$subscriptionId"
                $matching = @(@($state.Data.identities) | ForEach-Object { @($_.roleAssignments) } | Where-Object { $_ -and $_.role -eq $rule.role -and $_.scope -eq $scope })
                & $add $id "$($rule.count) x $($rule.role) at the subscription for the SRE identity" $matching.Count ($matching.Count -eq [int]$rule.count) ''
            }
            'onboardingApp' {
                $state = Get-SnapshotSection $Snapshot 'onboardingApp'
                if ($state.Ok) { & $add $id "application sp-$NamePrefix-onboard exists" $state.Data.found ([bool]$state.Data.found) '' } else { & $unavailable $id 'onboarding application' $state }
            }
            'noOneDayCredentials' {
                $state = Get-SnapshotSection $Snapshot 'onboardingApp'
                if (-not $state.Ok) { & $unavailable $id 'no residual one-day credentials' $state; continue }
                $residual = @(@($state.Data.credentials) | Where-Object {
                    $start = ConvertTo-SnapshotDate (Get-SnapshotValue $_ 'startDateTime')
                    $end = ConvertTo-SnapshotDate (Get-SnapshotValue $_ 'endDateTime')
                    $start -and $end -and ($end - $start).TotalDays -le 2 })
                & $add $id 'no credential that lives two days or less' @($residual | ForEach-Object { $_.displayName }) ($residual.Count -eq 0) 'A one-day build credential was not removed.'
            }
            'noLongLivedCredentials' {
                $state = Get-SnapshotSection $Snapshot 'onboardingApp'
                if (-not $state.Ok) { & $unavailable $id 'no credential that lives longer than two days' $state; continue }
                $long = @(@($state.Data.credentials) | Where-Object {
                    $start = ConvertTo-SnapshotDate (Get-SnapshotValue $_ 'startDateTime')
                    $end = ConvertTo-SnapshotDate (Get-SnapshotValue $_ 'endDateTime')
                    $start -and $end -and ($end - $start).TotalDays -gt 2 })
                & $add $id 'no credential that lives longer than two days' @($long | ForEach-Object { "$($_.displayName) until $((ConvertTo-SnapshotDate (Get-SnapshotValue $_ 'endDateTime')).ToString('yyyy-MM-dd'))" }) ($long.Count -eq 0) 'The build only ever mints one-day credentials. A longer one was left by the application''s creation (an older Deploy) or added by hand; deleting it is the owner''s decision (az ad app credential delete).'
            }
            default {
                $state = Get-SnapshotSection $Snapshot 'groups'
                $label = "$($rule.type) $(Get-SnapshotValue $rule 'name')".Trim()
                if (-not $state.Ok) { & $unavailable $id $label $state; continue }
                $group = Get-SnapshotValue $state.Data ([string]$rule.group)
                if (-not (Get-SnapshotValue $group 'exists')) { & $add $id $label 'group absent' $false "Resource group $(Get-SnapshotValue $group 'name') does not exist."; continue }
                $items = @(@($group.resources) | Where-Object { $_.type -eq $rule.type })
                $tags = Get-SnapshotValue $rule 'tags'
                if ($tags) { foreach ($tag in $tags.PSObject.Properties) { $items = @($items | Where-Object { (Get-SnapshotValue $_ "tags.$($tag.Name)") -eq $tag.Value }) } }
                $name = [string](Get-SnapshotValue $rule 'name')
                if ($name) { $name = & $expandName $name; $items = @($items | Where-Object { $_.name -eq $name }) }
                # tagNames: each named tag must be present with a value, whatever the value is (a skin may set its own).
                $tagNames = @(@(Get-SnapshotValue $rule 'tagNames') | Where-Object { $_ })
                $untagged = @()
                if ($tagNames.Count) {
                    $hasTags = { param($item) -not @($tagNames | Where-Object { -not (Get-SnapshotValue $item "tags.$_") }).Count }
                    $untagged = @($items | Where-Object { -not (& $hasTags $_) })
                    $items = @($items | Where-Object { & $hasTags $_ })
                    $label = "$label tagged $($tagNames -join ', ')"
                }
                $min = Get-SnapshotValue $rule 'min'
                $count = Get-SnapshotValue $rule 'count'
                $need = if ($null -ne $min) { [int]$min } elseif ($null -ne $count) { [int]$count } else { 1 }
                $ok = if ($null -ne $min) { $items.Count -ge $need } else { $items.Count -eq $need }
                $wording = if ($null -ne $min) { "at least $need" } else { "exactly $need" }
                $found = "Found $($items.Count)."
                if ($untagged.Count) { $found += " Without every required tag: $(@($untagged | ForEach-Object { $_.name }) -join ', ')." }
                & $add $id "$wording x $label" @($items | ForEach-Object { $_.name } | Select-Object -First 8) $ok $found
            }
        }
    }
    $fleet = Get-SnapshotSection $Snapshot 'fleet'
    $vmState = Get-SnapshotSection $Snapshot 'vms'
    $arcState = Get-SnapshotSection $Snapshot 'arcMachines'
    if ($fleet.Ok -and $vmState.Ok -and $arcState.Ok) {
        $machines = @($fleet.Data.machines)
        & $add 'fleet/manifest' 'a successful deployment manifest listing the fleet' $fleet.Data.deployment ($machines.Count -gt 0) 'No successful manifest with a deployed fleet was found.'
        $vmNames = @($vmState.Data | ForEach-Object { $_.name })
        $arcNames = @($arcState.Data | ForEach-Object { $_.name })
        foreach ($machine in $machines) {
            & $add "fleet/$($machine.name)/vm" 'Azure VM exists' ($machine.name -in $vmNames) ($machine.name -in $vmNames) ''
            & $add "fleet/$($machine.name)/arc" 'Arc machine exists' ($machine.name -in $arcNames) ($machine.name -in $arcNames) ''
            # Tags are compared only when both sides captured them: a manifest from before the fleet output carried
            # role and osTier, or a snapshot from before the Arc list kept tags, cannot be judged.
            $wantRole = [string](Get-SnapshotValue $machine 'role')
            $wantTier = [string](Get-SnapshotValue $machine 'osTier')
            $arcEntry = @($arcState.Data | Where-Object { $_.name -eq $machine.name }) | Select-Object -First 1
            if ($wantRole -and $wantTier -and $arcEntry -and (Test-SnapshotKey $arcEntry 'tags')) {
                $tagMap = ConvertTo-DemoTagMap (Get-SnapshotValue $arcEntry 'tags')
                $found = foreach ($tagName in 'role', 'osTier') { "$tagName=$(if ($tagMap.ContainsKey($tagName)) { $tagMap[$tagName] } else { '(missing)' })" }
                $wanted = "role=$wantRole, osTier=$wantTier"
                & $add "fleet/$($machine.name)/tags" "Arc machine tags $wanted" ($found -join ', ') (($found -join ', ') -ceq $wanted) 'The role/osTier tags the workbooks filter on are missing or wrong; Deploy merges them and skips a host that already matches.'
            }
        }
        $azureVmNames = @(@(Get-SnapshotValue $fleet.Data 'azureVmNames') | Where-Object { $_ })
        foreach ($name in $azureVmNames) {
            & $add "fleet/$name/vm" 'Azure VM exists' ($name -in $vmNames) ($name -in $vmNames) ''
        }
        $allowed = @($machines | ForEach-Object { $_.name }) + $azureVmNames + @($KeepParkedVmNames) + @($NestedParentVmName | Where-Object { $_ })
        $extra = @($vmNames | Where-Object { $_ -notin $allowed })
        & $add 'fleet/no-extra-vms' 'only manifest hosts, the nested parent and explicitly kept-parked VMs' $extra ($extra.Count -eq 0) 'A VM outside the manifest exists.'
        if ($NestedArcMachineName -and 'NestedSql' -in $Feature) {
            & $add 'fleet/nested-guest' "Arc machine $NestedArcMachineName exists" ($NestedArcMachineName -in $arcNames) ($NestedArcMachineName -in $arcNames) ''
        }
    }
    $failed = @($checks | Where-Object status -eq 'fail').Count
    [pscustomobject]@{ status = $(if ($failed) { 'fail' } else { 'pass' }); checks = $checks.ToArray() }
}

Export-ModuleMember -Function Get-DemoEstateSnapshot, Test-DemoEstateParity
